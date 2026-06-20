class_name InteractionSystem extends Node
## INTERACTION + DIALOGUE. Chest / NPC / SEAM, checked against RpgState. A SEAM is the real
## door: when unlocked it calls SceneManager.goto_area() -> the fade + area swap. NPC lines get
## a live in-character hint from the shared brain (npc.myapping.com/chat). Chests are real
## KayKit chest models with a gold sparkle; NPCs are retargeted to an idle clip (no T-pose).
## Visuals live under the current area root (freed on transition); clear() drops the refs.

const NPC_BRAIN := "https://npc.myapping.com/chat"

var player: Node3D
var rpg: RpgState
var scene_manager
var quest
var area_parent: Node
var items: Array = []

var prompt: Label
var dlg_box: PanelContainer
var dlg_label: RichTextLabel
var dlg_queue: Array = []
var active := false


func setup(p: Node3D, state: RpgState, sm, qs, hud: CanvasLayer) -> void:
	player = p
	rpg = state
	scene_manager = sm
	quest = qs
	_build_ui(hud)


func set_area_parent(node: Node) -> void:
	area_parent = node


func clear() -> void:
	items = []
	active = false
	if dlg_box:
		dlg_box.visible = false


func _physics_process(_d: float) -> void:
	if player == null or prompt == null:
		return
	if scene_manager and scene_manager.transitioning:
		prompt.text = ""
		return
	if active:
		prompt.text = "tap dialogue / USE to continue"
		return
	var it = _nearest(2.9)
	prompt.text = ("USE  >  " + str(it.label)) if it else ""


# ---------------- registration ----------------

func add_chest(pos: Vector3, contents: Array, gold := 0, model: Node = null) -> void:
	var node: Node3D
	if model and model is Node3D:
		node = model as Node3D
		node.position = pos
		node.rotation.y = randf() * TAU
		area_parent.add_child(node)
		_matte(node)
	else:
		node = _box(pos + Vector3(0, 0.45, 0), Vector3(0.9, 0.7, 0.9), Color(0.85, 0.68, 0.22))
	var sparkle := _sparkle(pos + Vector3(0, 1.0, 0))
	items.append({kind = "chest", pos = pos, node = node, sparkle = sparkle, label = "Open Chest",
		contents = contents, gold = gold, opened = false})


func _matte(root: Node3D) -> void:
	# kill harsh metallic sky-specular so the chest reads as a solid prop, not a white glint
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		for s in range(max(1, mi.mesh.get_surface_count())):
			var base: Material = mi.get_active_material(s)
			var m := (base.duplicate() if base else StandardMaterial3D.new()) as StandardMaterial3D
			if m == null:
				continue
			m.metallic = 0.0
			m.roughness = maxf(m.roughness, 0.85)
			mi.set_surface_override_material(s, m)


func add_npc(pos: Vector3, npc_id: String, npc_name: String, persona: String, lines: Array, model: Node = null) -> void:
	if model and model is Node3D:
		var m := model as Node3D
		m.position = pos
		area_parent.add_child(m)
		var ap := AnimRig.attach(m, {"idle": "Idle_A"}, ["idle"])
		ap.seek(randf() * 1.0, true)
		ap.play("idle")
	else:
		_capsule(pos, Color(0.30, 0.78, 0.42))
	items.append({kind = "npc", pos = pos, label = "Talk to " + npc_name, npc_id = npc_id,
		npc_name = npc_name, persona = persona, lines = lines, asked = false})


func add_seam(pos: Vector3, to_area: String, spawn: String, lock: String, label: String, hint := "") -> void:
	var col := Color(0.45, 0.62, 0.95) if lock == "" else Color(0.75, 0.42, 0.22)
	var node := _portal(pos, col, lock == "")
	items.append({kind = "seam", pos = pos, node = node, label = label,
		to = to_area, spawn = spawn, lock = lock, hint = hint})


# ---------------- use ----------------

func try_use() -> void:
	if scene_manager and scene_manager.transitioning:
		return
	if active:
		_advance()
		return
	var it = _nearest(3.0)
	if it == null:
		return
	match it.kind:
		"chest": _open_chest(it)
		"npc": _talk(it)
		"seam": _use_seam(it)


func _nearest(rng: float):
	var best = null
	var bd := rng
	for it in items:
		if it.kind == "chest" and it.opened:
			continue
		var d: float = player.global_position.distance_to(it.pos)
		if d < bd:
			bd = d
			best = it
	return best


func _open_chest(it: Dictionary) -> void:
	it.opened = true
	if is_instance_valid(it.sparkle):
		(it.sparkle as CPUParticles3D).emitting = false
	if is_instance_valid(it.node):
		var pop := (it.node as Node3D).create_tween()
		pop.tween_property(it.node, "scale", (it.node as Node3D).scale * 1.18, 0.12).set_trans(Tween.TRANS_BACK)
		pop.tween_property(it.node, "scale", (it.node as Node3D).scale, 0.12)
	var got: Array = []
	for entry in it.contents:
		rpg.add_item(entry)
		got.append(rpg.item_name(entry))
		if rpg.item_type(entry) == "weapon":
			rpg.equip(entry)
	if it.gold > 0:
		rpg.add_gold(it.gold)
		got.append("%d gold" % it.gold)
	_show(["You opened the chest.", "Found: " + ", ".join(got) + "."])


func _use_seam(it: Dictionary) -> void:
	if it.lock != "" and not rpg.has_item(it.lock) and not rpg.has_flag(it.lock):
		var msg: String = it.hint if String(it.get("hint", "")) != "" else "The way is sealed."
		_show(["The gate will not open.", msg])
		return
	scene_manager.goto_area(it.to, it.spawn)


func _talk(it: Dictionary) -> void:
	_show(it.lines.duplicate())
	if quest and String(it.get("npc_id", "")) != "":
		quest.notify_talk(it.npc_id)
	if not it.asked:
		it.asked = true
		_ask_brain(it)


# ---------------- dialogue ----------------

func _show(lines: Array) -> void:
	dlg_queue = lines.duplicate()
	active = true
	dlg_box.visible = true
	_advance(true)


func _advance(first := false) -> void:
	if not first and not dlg_queue.is_empty():
		dlg_queue.pop_front()
	if dlg_queue.is_empty():
		active = false
		dlg_box.visible = false
		return
	dlg_label.text = str(dlg_queue[0])


func _queue_line(text: String) -> void:
	if active:
		dlg_queue.append(text)


func _ask_brain(it: Dictionary) -> void:
	var req := HTTPRequest.new()
	add_child(req)
	req.request_completed.connect(func(_r: int, c: int, _h: PackedStringArray, b: PackedByteArray) -> void:
		if c == 200:
			var d = JSON.parse_string(b.get_string_from_utf8())
			if d is Dictionary and d.has("reply") and str(d["reply"]) != "":
				_queue_line(str(it.npc_name) + ": " + str(d["reply"]))
		req.queue_free())
	var payload := JSON.stringify({
		"persona": it.persona,
		"messages": [{"role": "user", "content": "Greet the hero in one short sentence and hint where to go next."}],
	})
	req.request(NPC_BRAIN, ["Content-Type: application/json"], HTTPClient.METHOD_POST, payload)


# ---------------- build helpers ----------------

func _build_ui(hud: CanvasLayer) -> void:
	prompt = Label.new()
	prompt.add_theme_font_size_override("font_size", 28)
	prompt.add_theme_color_override("font_color", Color(1, 1, 0.62))
	prompt.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	prompt.add_theme_constant_override("outline_size", 6)
	prompt.set_anchors_preset(Control.PRESET_CENTER)
	prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	prompt.offset_top = 120
	prompt.offset_left = -260
	prompt.offset_right = 260
	hud.add_child(prompt)

	dlg_box = PanelContainer.new()
	dlg_box.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	dlg_box.offset_left = 40
	dlg_box.offset_right = -40
	dlg_box.offset_top = -210
	dlg_box.offset_bottom = -150
	dlg_box.visible = false
	dlg_box.mouse_filter = Control.MOUSE_FILTER_STOP
	dlg_box.gui_input.connect(func(e: InputEvent) -> void:
		if (e is InputEventScreenTouch or e is InputEventMouseButton) and e.is_pressed():
			_advance())
	dlg_label = RichTextLabel.new()
	dlg_label.bbcode_enabled = true
	dlg_label.fit_content = true
	dlg_label.add_theme_font_size_override("normal_font_size", 26)
	dlg_box.add_child(dlg_label)
	hud.add_child(dlg_box)


func _sparkle(pos: Vector3) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	p.position = pos
	p.amount = 10
	p.lifetime = 1.2
	p.emitting = true
	p.direction = Vector3(0, 1, 0)
	p.spread = 22.0
	p.gravity = Vector3(0, 0.5, 0)
	p.initial_velocity_min = 0.25
	p.initial_velocity_max = 0.6
	p.scale_amount_min = 0.04
	p.scale_amount_max = 0.09
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.82, 0.32)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.74, 0.22)
	m.emission_energy_multiplier = 1.3
	p.mesh = SphereMesh.new()
	(p.mesh as SphereMesh).radius = 0.05
	(p.mesh as SphereMesh).height = 0.1
	p.material_override = m
	area_parent.add_child(p)
	return p


func _portal(pos: Vector3, col: Color, open: bool) -> MeshInstance3D:
	var body := StaticBody3D.new()
	body.position = pos + Vector3(0, 1.5, 0)
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(3.2, 3.0, 0.4)
	mi.mesh = bm
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 1.4 if open else 0.6
	mi.material_override = m
	body.add_child(mi)
	area_parent.add_child(body)
	return mi


func _box(pos: Vector3, sz: Vector3, col: Color) -> MeshInstance3D:
	var body := StaticBody3D.new()
	body.position = pos
	body.collision_layer = 1
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = sz
	mi.mesh = bm
	mi.material_override = _mat(col)
	body.add_child(mi)
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = sz
	cs.shape = bs
	body.add_child(cs)
	area_parent.add_child(body)
	return mi


func _capsule(pos: Vector3, col: Color) -> void:
	var mi := MeshInstance3D.new()
	var cm := CapsuleMesh.new()
	cm.radius = 0.4
	cm.height = 1.7
	mi.mesh = cm
	mi.position = pos + Vector3(0, 0.85, 0)
	mi.material_override = _mat(col)
	area_parent.add_child(mi)


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m
