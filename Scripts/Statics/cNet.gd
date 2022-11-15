class_name Net extends Node


static func get_dict_data(p_peer, p_timeout: int) -> Dictionary:
	
	var d: Dictionary
	var end_tm: int = Time.get_ticks_msec() + p_timeout
	while p_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		if end_tm < Time.get_ticks_msec():
#			print("break")
			break
		if p_peer.get_available_bytes() > 0:
			var pd = p_peer.get_var()
			if typeof(pd) == TYPE_DICTIONARY:
				d = pd.duplicate(true)
				break
	return d


static func ssl_connect(tcp_peer:StreamPeerTCP, timeout:int) -> StreamPeerSSL:
	
	var ssl_peer := StreamPeerSSL.new()
	var err:int = ssl_peer.connect_to_stream(tcp_peer, false)
	if err: 
		print("Net.ssl_connect error:", err)
		ssl_peer = null
		return ssl_peer
	
	var conn_timeout:int = OS.get_ticks_msec() + timeout
	while (ssl_peer.get_status() == StreamPeerSSL.STATUS_HANDSHAKING && 
		OS.get_ticks_msec() < conn_timeout && err == 0):
		pass
	
	if (ssl_peer.get_status() == StreamPeerSSL.STATUS_HANDSHAKING || 
			ssl_peer.get_status() != StreamPeerSSL.STATUS_CONNECTED && err == 0):
		print("SSL Not Completing Handshake")
		ssl_peer = null
	
	return ssl_peer


static func tcp_connect(url:String, port:int, timeout:int) -> StreamPeerTCP:
	
	var tcp_peer := StreamPeerTCP.new()
	var err:int = tcp_peer.connect_to_host(url, port)
	if err :
		print(url, ":", port, " Net.tcp_connect error:", err)
	
	var conn_timeout:int = OS.get_ticks_msec() + timeout
	while (err == OK && 
			tcp_peer.get_status() == StreamPeerTCP.STATUS_CONNECTING && 
			OS.get_ticks_msec() < conn_timeout):
		pass
	
	if (err || tcp_peer.get_status() == StreamPeerTCP.STATUS_CONNECTING || 
			tcp_peer.get_status() != StreamPeerTCP.STATUS_CONNECTED):
		print(url, ":", port, " cannot connect to host")
		err = ERR_CANT_CONNECT
	
	if err:
		tcp_peer = tcp_disconnect(tcp_peer)
	
	return tcp_peer


static func tcp_disconnect(tcp_peer:StreamPeerTCP) -> StreamPeerTCP:
	
	if tcp_peer != null:
		tcp_peer.disconnect_from_host()
	tcp_peer = null
	return tcp_peer


# Return the bytes downloaded
# Note - timeout should be lower than max allowed so the server does not disco
static func tcp_rcv_file(p_peer: StreamPeerTCP, p_file: String, p_timeout: int, 
		p_signal_node: Object = null, p_signal_name: String = "") -> int:
	
	var f: File = File.new()
	if f.open(p_file, File.WRITE) != OK:
		return -1

	var idle_tm: int = Time.get_ticks_msec() + p_timeout 
	var dl_bytes: int = 0
	while (p_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED &&
			Time.get_ticks_msec() < idle_tm):
		var ab: int = p_peer.get_available_bytes()
		if ab > 0:
			var bytes: Array = p_peer.get_data(ab)
			idle_tm = Time.get_ticks_msec() + p_timeout
			if bytes[0] == OK:
				f.store_buffer(bytes[1])
				if p_signal_node != null && p_signal_name != "":
					p_signal_node.emit_signal(p_signal_name, ab)
				dl_bytes += ab
			else:
				print("Net.tcp_rcv_file() peer.get_data error code:", bytes[0])
	
	f.close()
	return dl_bytes


#TODO make ssl_send_file
static func tcp_send_file(p_peer: StreamPeerTCP, p_file: String) -> int:
	
	var f: File = File.new()
	if f.open(p_file, File.READ) != OK:
		print("Net.tcp_send_file() open file err")
		return 0
	var l := f.get_len()
	var p := f.get_position()
	var r: int = l - p
	while p < l:
		r = l - p
		#size accounts for vpn header, standard ipsec mtu setting is 1400
		if r > 1400: 
			r = 1400
		var pba := f.get_buffer(r)
		if p_peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			if p_peer.put_data(pba) != OK:
				print("Net.tcp_send_file put_data error")
				return -1
		else:
			break
		p = f.get_position()
	
	f.close()
	return p


