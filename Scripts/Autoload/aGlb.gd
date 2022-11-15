extends Node

enum {
	FUNC_UPDATE_LAUNCHER = 0,
	FUNC_UPDATE_GAME = 1,
	FUNC_TOTAL_BYTES = 2,
	FUNC_SEND_FILE = 3,
	FUNC_QUIT = 4
}

enum {
	STATUS_OK = 0,
	STATUS_CONT = 1,
	STATUS_BUSY = 2,
	STATUS_NEXT = 3,
	STATUS_DONE = 4
}

var exe_dir: String


func _ready() -> void:
	if OS.has_feature("editor"):
		exe_dir = ProjectSettings.globalize_path("res://")
	else:
		exe_dir = OS.get_executable_path().get_base_dir() + "/"
