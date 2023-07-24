#Note - This does no security checking it soul purpose is to update files it is 
#	asked, the game server should ultimately determine patch validity

#TODO - Check hashes and file list to what is in filesystem periodically
# set connection blocking and disconnect signals saying to try back in a few. 

#TODO - Implement resume download, client send the current files size, srvr starts sending at that position

extends Node2D

const kMaxConn: int = 1024
const kConnTimeout_MS: int = 5000
const kUpdateInterval: float = 10.0

const kRawDir: String = "RawFiles/"
const kCompressedir: String = "CompressedFiles/"
#make sure compression type is consistant throughout 
const kCompressTypeID: int = File.COMPRESSION_ZSTD
const kPatcherFilesDir: String = "PatcherFiles/"
const kPatcherManifest_fn: String = "patcher_manifest.json"
const kGameDir: String = "GameFiles/"
const kGameManifest_fn: String = "game_manifest.json"
#from OS.get_name() return list, PC pnly, app stores have their own update service
# not sure how to make sure the list is consistant if Godot changes OS names
const kOSes: Array = ["Windows", "X11", "OSX"]

var _running_: bool = true

var _tcp_server_: TCP_Server setget _noset
var _tcp_conns_:int = 0 setget _noset
var _tcp_peer_thrds_mutex_ := Mutex.new() setget _noset 

#Commonly used, made globals for efficiency
var _compression_ext_: String = "" setget _noset

var _manifest_changed_: bool = false
var _update_timer_: float = 0.0
var _update_thr_: Thread = Thread.new()
var _update_sema_: Semaphore = Semaphore.new()
var _game_manifest_: Dictionary setget _noset
var _live_game_manifest_: Dictionary setget _noset
var _patcher_manifest_: Dictionary setget _noset
var _live_patcher_manifest_: Dictionary setget _noset


func _noset(_void) -> void:
	return


func _exit_tree() -> void:
	_running_ = false
# warning-ignore:return_value_discarded
	_update_sema_.post()
	Utils.thread_finished(_update_thr_)


func _ready() -> void:
	_compression_ext_ = FileTool.get_compress_type_ext(kCompressTypeID)
	var cfd: String = Glb.exe_dir + kCompressedir
	if !FileTool.file_exists(cfd + kPatcherManifest_fn):
# warning-ignore:return_value_discarded
		FileTool.save_json(cfd + kPatcherManifest_fn, {}, true)
	if !FileTool.file_exists(cfd + kGameManifest_fn):
# warning-ignore:return_value_discarded
		FileTool.save_json(cfd + kGameManifest_fn, {}, true)
	var err = _update_thr_.start(self, "m_update_manifest_thr")
	if err:
		printerr("Main.m_check_manifests() thread start err:" + str(err))
# warning-ignore:return_value_discarded
	_update_sema_.post()
	m_start_listening()


func _process(p_delta: float) -> void:
	if !_running_:
		return
	_update_timer_ += p_delta
	if _update_timer_ > kUpdateInterval:
		_update_timer_ -= kUpdateInterval
# warning-ignore:return_value_discarded
		_update_sema_.post()
	m_check_for_tcp()


func m_build_manifest(p_search_path: String, p_manifest: Dictionary, 
		p_json_path: String, p_export_path: String) -> void:
			
	for os in kOSes:
		var search_path: String = p_search_path + os + "/"
		var found_files: Array = FileTool.get_paths(search_path, true)
#		print("Main.m_build_manifests() found_files:", found_files)
		if found_files.size() == 0:
			continue
		
		for fn in found_files:
			var from_file: String = search_path + fn
			var md5hash: String = FileTool.get_file_md5(from_file)
#			print("Main.m_build_manifests() md5hash:", md5hash)
			if md5hash == "":
				continue
			
			if !p_manifest.has(os):
				p_manifest[os] = {}
			elif typeof(p_manifest[os]) != TYPE_DICTIONARY:
					p_manifest[os] = {}
			
			var os_dir: Dictionary = p_manifest[os]
			var v: String
			if os_dir.has(fn):
				if typeof(os_dir[fn]) != TYPE_DICTIONARY:
					os_dir[fn] = {}
				elif os_dir[fn].has("md5hash"):
					v = os_dir[fn]["md5hash"]
			else:
				os_dir[fn] = {}
			
			var to_file: String = p_export_path + os + "/" + fn + _compression_ext_
			if v != md5hash:
				_manifest_changed_ = true
				var comp_file: String = FileTool.compress(from_file, 
						kCompressTypeID, to_file)
				if comp_file != "":
					os_dir[fn]["comp_file"] =  comp_file
					os_dir[fn]["comp_type"] =  kCompressTypeID
					os_dir[fn]["md5hash"] = md5hash
				else:
					printerr("Error compressing file:", from_file)
			
			if !FileTool.file_exists(os_dir[fn]["comp_file"]):
				var comp_path:String = FileTool.compress(from_file, 
						kCompressTypeID, to_file)
				if comp_path != "":
					os_dir[fn]["comp_path"] = comp_path
				else:
					os_dir[fn]["md5hash"] = ""
					printerr("Error compressing file:", from_file)
	#look for file entries that do not exist in raw 
	for os_k in p_manifest.keys():
		for path_k in p_manifest[os_k].keys():
			if !FileTool.file_exists(p_search_path + os_k + "/" + path_k):
# warning-ignore:return_value_discarded
				FileTool.file_remove(p_manifest[os_k][path_k]["comp_file"])
				if p_manifest[os_k].erase(path_k):
					_manifest_changed_ = true
	
	if _manifest_changed_:
		if FileTool.save_json(p_json_path, p_manifest, true) != OK:
			printerr("error saving manifest")


func m_check_for_tcp() -> void:
	if _tcp_server_ == null:
		printerr("server off")
		return
	if _tcp_server_.is_connection_available():
		var tcp_peer: StreamPeerTCP = _tcp_server_.take_connection()
		if _tcp_conns_ < kMaxConn || !_manifest_changed_:
			var thr := Thread.new()
			var err = thr.start(self, "m_tcp_thread", {
				"tcp_peer": tcp_peer, "thread": thr})
			if err:
				printerr("thread start err:" + str(err))
				tcp_peer = Net.tcp_disconnect(tcp_peer)
			else:
				_tcp_conns_ += 1
		else:
			tcp_peer = Net.tcp_disconnect(tcp_peer)


func m_get_tx_manifest(p_peer_list: Dictionary, p_srvr_list: Dictionary) -> Dictionary:
	var rtn: Dictionary = {"files": {}}
	var bytes: int = 0
	var add_file: bool = false
	for fn_key in p_srvr_list.keys():
		add_file = false
		if !p_srvr_list[fn_key].has_all(["md5hash", "comp_file"]):
			printerr("Server manifest missing keys!")
			continue
		
		if p_peer_list.has(fn_key):
			if !p_peer_list[fn_key].has("md5hash"):
				printerr("Peer manifest missing hash key!")
				continue
			else:
				add_file = p_peer_list[fn_key]["md5hash"] != p_srvr_list[fn_key]["md5hash"]
			
		else:
			add_file = true
		
		if add_file:
			var b:int = FileTool.get_size(p_srvr_list[fn_key]["comp_file"])
			if b < 0:
				return {}
			bytes += b
			rtn["files"][fn_key] = {
					"size": b, 
					"comp_type": p_srvr_list[fn_key]["comp_type"]
				}
	
	rtn["total_bytes"] = bytes
	return rtn


func m_start_listening() -> void:
	if _tcp_server_ == null:
		_tcp_server_ = TCP_Server.new()
	elif _tcp_server_.is_listening():
		_tcp_server_.stop()
		yield(get_tree().create_timer(1.0), "timeout")
	
	if _tcp_server_.listen(4242) != OK:
		printerr("Error opening tcp listen port:", 4242)
		get_tree().quit()


func m_tcp_thread(p_d: Dictionary) -> void:
	var thr:Thread = p_d.thread
	var peer: StreamPeerTCP = p_d.tcp_peer
#	print("Connected Peer:", peer.get_connected_host(), ":", peer.get_connected_port(), "\n")
	var idle_tm: int = Time.get_ticks_msec() + kConnTimeout_MS
	while Time.get_ticks_msec() < idle_tm: 
		var pd: Dictionary = Net.get_dict_data(peer, kConnTimeout_MS)
#		print("pd:", pd)
		if pd.has("func"):
			match pd.func:
				Glb.FUNC_UPDATE_LAUNCHER:
					#blocking will need to get bytes in func
					var err: int = m_update_client(peer, pd, _live_patcher_manifest_)
					if err != OK:
						print("Main.m_tcp_thread() Error Sending Launcher Patch")
						peer.put_var({
							"func": pd.func, 
							"error": err
							})
						break
					idle_tm = Time.get_ticks_msec() + kConnTimeout_MS
				Glb.FUNC_UPDATE_GAME:
					# blocking will need to get bytes in func
					var err: int = m_update_client(peer, pd, _live_game_manifest_)
					if err != OK:
						print("Main.m_tcp_thread() Error Sending Game Patch")
						peer.put_var({
							"func": pd.func, 
							"error": err
							})
					break
				Glb.FUNC_QUIT:
					break
		else:
			break
	
#	print("Disonnecting Peer:", peer.get_connected_host())
	peer = Net.tcp_disconnect(peer)
	call_deferred("m_tcp_thread_finished", thr)


func m_tcp_thread_finished(p_thr: Thread) -> void:
	Utils.thread_finished(p_thr)
	if _running_:
		_tcp_conns_ -= 1


func m_thread_finished(p_thr: Thread) -> void:
	Utils.thread_finished(p_thr)


func m_update_client(p_peer: StreamPeerTCP, p_peerdata: Dictionary, 
		p_manifest: Dictionary) -> int:
#	var ip: String = p_peer.get_connected_host()
#	var port: int =  p_peer.get_connected_port()
#	print()
#	print("Main.m_update_client()", ip, ":", port)
#	print("p_peerdata:", p_peerdata)
	if !p_peerdata.has("os"):
#		print("Main.update_client no os key")
		return ERR_INVALID_DATA
	
	if !p_manifest.has(p_peerdata.os):
		#no files for manifest to create, assume intended
#		print("No files for OS:", p_peerdata["os"])
		p_peer.put_var({
			"func": Glb.FUNC_TOTAL_BYTES,
			"status": Glb.STATUS_DONE
			})
		return OK
	
	var osm: Dictionary = p_manifest[p_peerdata.os]
	if !p_peerdata.has("manifest"):
		return ERR_INVALID_DATA
	
	var tx: Dictionary = m_get_tx_manifest(p_peerdata.manifest, osm)
#	print("tx:", tx)
	if tx == {}:
		printerr("Main.update_client error getting mainfest")
		return ERR_QUERY_FAILED
	if tx.total_bytes > 0:
		p_peer.put_var({
			"func": Glb.FUNC_TOTAL_BYTES, 
			"total_bytes": tx.total_bytes
			})
	else:
		p_peer.put_var({
			"func": Glb.FUNC_TOTAL_BYTES,
			"status": Glb.STATUS_DONE
			})
		return OK
	
	var peer_d: Dictionary = Net.get_dict_data(p_peer, kConnTimeout_MS)
	if Utils.dict_has_key_val(peer_d, {
			"func": Glb.FUNC_TOTAL_BYTES,
			"status": null
			}):
		if peer_d["status"] == Glb.STATUS_DONE:
			return OK
		elif peer_d["status"] != Glb.STATUS_CONT:
			return ERR_INVALID_PARAMETER
	else:
		return ERR_INVALID_PARAMETER
	
	#rcvd cont tx files
	for fn in tx.files.keys():
#		print("out:", {
#			"file": fn,
#			"type": tx.files[fn]["comp_type"],
#			"size": tx.files[fn]["size"]
#			})
		p_peer.put_var({
			"file": fn,
			"type": tx.files[fn]["comp_type"],
			"size": tx.files[fn]["size"]
		})
		peer_d = Net.get_dict_data(p_peer, kConnTimeout_MS)
		if !Utils.dict_has_key_val(peer_d, {
				"func": Glb.FUNC_SEND_FILE,
				"status": Glb.STATUS_CONT
				}):
			return ERR_INVALID_PARAMETER
		
		#send file
# warning-ignore:return_value_discarded
		Net.tcp_send_file(p_peer, osm[fn]["comp_file"])
		#LOOP and wait for cont from client before sending next file
		peer_d = Net.get_dict_data(p_peer, kConnTimeout_MS)
		if !Utils.dict_has_key_val(peer_d, {
				"func": Glb.FUNC_SEND_FILE,
				"status": Glb.STATUS_NEXT
				}):
			break
	
	p_peer.put_var({
		"func": Glb.FUNC_TOTAL_BYTES,
		"status": Glb.STATUS_DONE
		})
	peer_d = Net.get_dict_data(p_peer, kConnTimeout_MS)
	
	return OK


func m_update_manifest_thr(_void) -> void:
	var cfd: String = Glb.exe_dir + kCompressedir
	_patcher_manifest_ = FileTool.read_json(cfd + kPatcherManifest_fn)
	_game_manifest_ = FileTool.read_json(cfd + kGameManifest_fn)
#	for os in kOSes:
#		if !_patcher_manifest_.has(os):
#			_patcher_manifest_[os] = {}
#		if !_game_manifest_.has(os):
#			_game_manifest_[os] = {}
	_live_patcher_manifest_ = _patcher_manifest_.duplicate(true)
	_live_game_manifest_ = _game_manifest_.duplicate(true)
	while _running_:
# warning-ignore:return_value_discarded
		_update_sema_.wait()
		if !_running_:
			break
		
		m_build_manifest(Glb.exe_dir + kRawDir + kPatcherFilesDir, 
				_patcher_manifest_, cfd + kPatcherManifest_fn, 
				cfd + kPatcherFilesDir)
		
		m_build_manifest(Glb.exe_dir + kRawDir + kGameDir, 
				_game_manifest_, cfd + kGameManifest_fn, 
				cfd + kGameDir)
		
		if _manifest_changed_:
#			print("manifest changed")
			while _tcp_conns_ > 0:
				pass
			_patcher_manifest_ = FileTool.read_json(cfd + kPatcherManifest_fn)
			_game_manifest_ = FileTool.read_json(cfd + kGameManifest_fn)
			_live_patcher_manifest_ = _patcher_manifest_.duplicate(true)
			_live_game_manifest_ = _game_manifest_.duplicate(true)
			_manifest_changed_ = false
