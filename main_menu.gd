# main_menu.gd
# Attach to the root Control node of main_menu.tscn.
#
# ── REQUIRED SCENE STRUCTURE ──────────────────────────────────────────────────
#
#   Control  (this script)
#   └── VBoxContainer  (or any layout container)
#       ├── StatusLabel   (Label)          ← displays connection state
#       ├── IPLineEdit    (LineEdit)        ← IP address input for joining
#       ├── HostButton    (Button)          ← starts server + loads arena
#       ├── JoinButton    (Button)          ← connects to IP + loads arena
#       └── PortLineEdit  (LineEdit)        ← optional; defaults to 7777
#
# ── WIRING ────────────────────────────────────────────────────────────────────
# In the Godot editor, connect button pressed signals to this script OR let
# _ready() do it in code (both approaches shown — code wiring is used here so
# the scene file stays minimal and the connections are version-control friendly).
#
# ── STATUS LABEL STATES ───────────────────────────────────────────────────────
#   "Hosting on port XXXX — waiting for opponent…"   after host_game()
#   "Connecting to IP:PORT…"                          during join_game()
#   "Connected! Loading arena…"                       on connected_to_server
#   "Connection failed — check the IP and try again." on connection_failed
#   "ERROR: …"                                        on port/peer errors
#
extends Control

# ── Node refs — adjust paths if your layout differs ──────────────────────────
@onready var _status_label:  Label    = $StatusLabel
@onready var _ip_line_edit:  LineEdit = $IPLineEdit
@onready var _port_line_edit: LineEdit = $PortLineEdit
@onready var _host_button:   Button   = $HostButton
@onready var _join_button:   Button   = $JoinButton

# Default values shown in the input fields on startup
const DEFAULT_IP:   String = "127.0.0.1"
const DEFAULT_PORT: String = "7777"


func _ready() -> void:
	# Pre-fill sensible defaults
	_ip_line_edit.text   = DEFAULT_IP
	_port_line_edit.text = DEFAULT_PORT
	_status_label.text   = "Enter an IP and press Join, or Host a game."

	# Wire buttons in code — no signal connections needed in the .tscn editor
	_host_button.pressed.connect(_on_host_pressed)
	_join_button.pressed.connect(_on_join_pressed)

	# Mirror NetworkManager status into the label for the whole lifetime of
	# this scene (connect/failed happen before scene change, so this is safe)
	NetworkManager.status_changed.connect(_on_status_changed)
	NetworkManager.connection_failed.connect(_on_connection_failed)


# ── Button handlers ───────────────────────────────────────────────────────────

func _on_host_pressed() -> void:
	var port := _parse_port(_port_line_edit.text)
	_set_buttons_enabled(false)
	NetworkManager.host_game(port)


func _on_join_pressed() -> void:
	var ip   := _ip_line_edit.text.strip_edges()
	var port := _parse_port(_port_line_edit.text)

	if ip.is_empty():
		_status_label.text = "Please enter an IP address."
		return

	_set_buttons_enabled(false)
	NetworkManager.join_game(ip, port)


# ── NetworkManager callbacks ──────────────────────────────────────────────────

func _on_status_changed(message: String) -> void:
	_status_label.text = message


func _on_connection_failed() -> void:
	# Re-enable inputs so the user can try again
	_set_buttons_enabled(true)


# ── Helpers ───────────────────────────────────────────────────────────────────

func _parse_port(text: String) -> int:
	var p := text.strip_edges().to_int()
	return p if p > 0 else NetworkManager.DEFAULT_PORT


func _set_buttons_enabled(enabled: bool) -> void:
	_host_button.disabled  = not enabled
	_join_button.disabled  = not enabled
	_ip_line_edit.editable = enabled
