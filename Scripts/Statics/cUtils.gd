extends Node
class_name Utils


static func copy_dict_key(p_from: Dictionary, p_to: Dictionary, p_key: String) -> Dictionary:
	if p_from.has(p_key):
		p_to[p_key] = p_from[p_key]
	else:
		p_to = {}
	return p_to


static func dict_has_key_val(p_dict: Dictionary, p_key_val := Dictionary()) -> bool:
	var has: bool = true
	var keys: Array = p_key_val.keys()
	for k in keys:
		has = has && p_dict.has(k)
		if has:
			has = has && (p_dict[k] == p_key_val[k] || p_key_val[k] == null)
		if !has:
			break
	return has


static func thread_array_finished(thr_arr:Array, thr_inst_id:int, mutex:Mutex) -> void:
	mutex.lock()
	for thr in thr_arr:
#		print("thr.get_instance_id():", thr.get_instance_id())
		if thr.get_instance_id() == thr_inst_id:
			thread_finished(thr)
	mutex.unlock()
	thread_array_clean(thr_arr, mutex)


static func thread_finished(p_thr:Thread) -> void:
	if p_thr == null: return
	var ms:int = OS.get_ticks_msec()
	while p_thr.is_alive():
		if OS.get_ticks_msec() - ms > 1000:
			ms = OS.get_ticks_msec()
			print("Thread still alive thr:", p_thr)
	if p_thr.is_active():
		p_thr.wait_to_finish()


static func thread_array_clean(thr_arr:Array, thr_arr_mutex:Mutex) -> void:
	thr_arr_mutex.lock()
	for idx in range(thr_arr.size() - 1, -1, -1):
		if thr_arr[idx] != null:
			if !thr_arr[idx].is_alive():
				thread_finished(thr_arr[idx])
				thr_arr.remove(idx)
		else:
			thr_arr.remove(idx)
	thr_arr_mutex.unlock()
