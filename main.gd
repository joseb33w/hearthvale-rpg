extends Node3D
## HEARTHVALE — RPG streaming orchestration. Fetches a fetchable world.json + quests.json
## (loose files next to index.html) + the asset manifest, wires the streaming systems, and
## keeps the persistent KayKit Knight hero / combat / camera / HUD across area transitions.
## Areas + their .glb stream from R2. Edits come from the chat (qgcheck-gated); this polls
## world.json and hot-reloads the live area when it changes (no re-export).

const L_WORLD := 1
const L_PLAYER := 2
const L_ENEMY := 4
const OUTLINE_SHADER := preload("res://shaders/outline.gdshader")

const RUN_SPEED := 6.0
const WALK_SPEED := 3.4

var origin := "https://preview.myapping.com"
var world_url := "https://preview.myapping.com/world.json"
var build_id := ""
var props_pool: Array = []

var world_data := {}
var quests_data := {}
var _world_raw := ""
var _polling := false
var _won := false

var env: Environment
var sun: DirectionalLight3D
var sky_day: Sky
var sky_grey: Sky

var player: CharacterBody3D
var knight: Node3D
var hero_anim: AnimationPlayer
var _hero_state := ""
var cam: Camera3D
const CAM_OFFSET := Vector3(0, 14.0, 9.0)
var swing_t := 0.0
var _shake_t := 0.0

var rpg: RpgState
var builder: AreaBuilder
var interaction: InteractionSystem
var scene_manager: SceneManager
var quest: QuestSystem

var started := false
var move_idx := -1
var move_origin := Vector2.ZERO
var move_vec := Vector2.ZERO
var insets := {"top": 0.0, "bottom": 0.0, "left": 0.0, "right": 0.0}

var hud_layer: CanvasLayer
var stats: Label
var hp_bar: ColorRect
var hp_bg: ColorRect
var joy_base: Panel
var joy_knob: Panel
var btn_attack: Button
var btn_use: Button
var btn_potion: Button
var overlay: CanvasLayer
var victory: Control


func _ready() -> void:
	if OS.has_feature("web"):
		var o = JavaScriptBridge.eval("window.location.origin", true)
		if typeof(o) == TYPE_STRING and String(o) != "":
			origin = String(o)
		var dir = JavaScriptBridge.eval("window.location.href.replace(/[^/]*$/, '')", true)
		if typeof(dir) == TYPE_STRING and String(dir) != "":
			world_url = String(dir) + "world.json"
		var bid = JavaScriptBridge.eval("location.pathname.split('/').filter(Boolean)[0] || ''", true)
		if typeof(bid) == TYPE_STRING and String(bid) != "":
			build_id = String(bid)

	var w := get_window()
	w.content_scale_mode = Window.CONTENT_SCALE_MODE_CANVAS_ITEMS
	w.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	get_viewport().msaa_3d = Viewport.MSAA_2X

	_build_env()
	_build_player()
	_build_camera()
	_build_hud()
	_build_overlay()

	rpg = RpgState.new()
	add_child(rpg)
	rpg.changed.connect(_update_stats)

	builder = AreaBuilder.new()
	builder.origin = origin
	builder.env = env
	builder.sun = sun
	builder.sky_day = sky_day
	builder.sky_grey = sky_grey
	add_child(builder)

	interaction = InteractionSystem.new()
	add_child(interaction)

	scene_manager = SceneManager.new()
	add_child(scene_manager)

	quest = QuestSystem.new()
	add_child(quest)
	quest.setup(rpg)
	quest.objective_changed.connect(_update_stats)

	interaction.setup(player, rpg, scene_manager, quest, hud_layer)
	scene_manager.setup(player, builder, interaction, self, hud_layer)
	scene_manager.area_entered.connect(quest.notify_area)
	scene_manager.area_entered.connect(_on_area_entered)

	w.size_changed.connect(_relayout)
	_read_insets()
	_relayout()
	await get_tree().process_frame
	await get_tree().process_frame
	_read_insets()
	_relayout()

	var poll := Timer.new()
	poll.wait_time = 4.0
	poll.autostart = true
	poll.timeout.connect(_poll_world)
	add_child(poll)

	_update_stats()
	_boot()


func _boot() -> void:
	var man := HTTPRequest.new()
	add_child(man)
	man.request(origin + "/godot-assets/manifest.json")
	var mr = await man.request_completed
	man.queue_free()
	if mr[1] == 200:
		_parse_manifest(mr[3])
	builder.props_pool = props_pool

	var wq := HTTPRequest.new()
	add_child(wq)
	wq.request(world_url)
	var wr = await wq.request_completed
	wq.queue_free()
	if wr[1] != 200:
		stats.text = "world.json fetch failed (HTTP %s)" % str(wr[1])
		return
	var raw := (wr[3] as PackedByteArray).get_string_from_utf8()
	var world = JSON.parse_string(raw)
	if not (world is Dictionary):
		stats.text = "world.json parse error"
		return
	world_data = world
	_world_raw = raw

	var qq := HTTPRequest.new()
	add_child(qq)
	qq.request(world_url.replace("world.json", "quests.json"))
	var qr = await qq.request_completed
	qq.queue_free()
	if qr[1] == 200:
		var qdata = JSON.parse_string((qr[3] as PackedByteArray).get_string_from_utf8())
		if qdata is Dictionary:
			quests_data = qdata
			quest.load_quests(qdata)
			var first_quest = quests_data.get("quests", [])
			if first_quest.size() > 0:
				quest.start(first_quest[0].get("id", ""))

	scene_manager.start(world)


func _physics_process(delta: float) -> void:
	if player == null or scene_manager == null:
		return
	_update_camera(delta)
	if scene_manager.transitioning or scene_manager.current_root == null or not started:
		_drive_hero(0.0)
		return
	var v := _keyboard_vec() + move_vec
	if v.length() > 1.0:
		v = v.normalized()
	var dir := Vector3(v.x, 0.0, v.y)
	var spd := RUN_SPEED if v.length() > 0.85 else (WALK_SPEED if v.length() > 0.15 else 0.0)
	player.velocity = dir * (spd if spd > 0.0 else 0.0)
	if dir.length() > 0.1:
		var look := player.global_position - dir
		player.look_at(Vector3(look.x, player.global_position.y, look.z), Vector3.UP)
	player.move_and_slide()
	swing_t = max(0.0, swing_t - delta)
	_drive_hero(player.velocity.length())


func _drive_hero(speed: float) -> void:
	if hero_anim == null:
		return
	var state := "idle"
	if swing_t > 0.0:
		state = "attack"
	elif speed > RUN_SPEED * 0.7:
		state = "run"
	elif speed > 0.4:
		state = "walk"
	if state == _hero_state and state != "attack":
		return
	_hero_state = state
	if hero_anim.has_animation(state):
		hero_anim.play(state, 0.12)
		if state == "attack":
			hero_anim.seek(0.0, true)


func _process(_delta: float) -> void:
	_update_joystick()
	if stats:
		_refresh_stats()


# ---------------- HUD ----------------

func _update_stats() -> void:
	_refresh_stats()
	if hp_bar and rpg:
		hp_bar.size.x = hp_bg.size.x * clamp(rpg.hp / rpg.max_hp, 0.0, 1.0)


func _refresh_stats() -> void:
	if rpg == null or stats == null:
		return
	var obj := quest.current_objective() if quest else ""
	stats.text = "Lv %d   HP %d/%d   Gold %d   Wpn: %s\n%s" % [
		rpg.level, int(rpg.hp), int(rpg.max_hp), rpg.gold, rpg.item_name(rpg.equipped_weapon), obj]


# ---------------- combat ----------------

func _attack() -> void:
	if not started or scene_manager == null or scene_manager.transitioning or swing_t > 0.0:
		return
	swing_t = 0.45
	_drive_hero(0.0)
	var dmg := rpg.weapon_damage()
	# face/snap toward the nearest enemy in range so a stationary tap doesn't whiff
	var target = _nearest_enemy(3.0)
	if target != null:
		var to: Vector3 = target.global_position - player.global_position
		to.y = 0.0
		if to.length() > 0.2:
			var look := player.global_position - to
			player.look_at(Vector3(look.x, player.global_position.y, look.z), Vector3.UP)
	var fwd := -player.global_transform.basis.z
	var hit_any := false
	for e in scene_manager.enemies:
		if not is_instance_valid(e) or e.dead:
			continue
		var to: Vector3 = e.global_position - player.global_position
		to.y = 0.0
		if to.length() < 2.8 and fwd.dot(to.normalized()) > 0.2:
			e.take_hit(dmg)
			_spark(e.global_position + Vector3(0, 1.0, 0), Color(1.0, 0.92, 0.5))
			hit_any = true
	if hit_any:
		add_shake(0.5)


func _nearest_enemy(rng: float):
	var best = null
	var bd := rng
	for e in scene_manager.enemies:
		if not is_instance_valid(e) or e.dead:
			continue
		var d: float = player.global_position.distance_to(e.global_position)
		if d < bd:
			bd = d
			best = e
	return best


func take_damage(d: float) -> void:
	if scene_manager == null or scene_manager.transitioning:
		return
	add_shake(0.35)
	if rpg.take_damage(d):
		rpg.hp = rpg.max_hp
		_spark(player.global_position + Vector3(0, 1.0, 0), Color(0.9, 0.3, 0.3))
		var sp = scene_manager.areas[scene_manager.current_id].spawns.keys()[0]
		scene_manager.goto_area(scene_manager.current_id, sp)


func on_enemy_killed(type: String) -> void:
	if rpg:
		rpg.grant_xp(18)
	if quest:
		quest.notify_kill(type)


func add_shake(a: float) -> void:
	_shake_t = max(_shake_t, a)


func _spark(pos: Vector3, col: Color) -> void:
	var p := CPUParticles3D.new()
	add_child(p)
	p.global_position = pos
	p.amount = 18
	p.lifetime = 0.5
	p.one_shot = true
	p.emitting = true
	p.explosiveness = 0.9
	p.direction = Vector3(0, 1, 0)
	p.spread = 80.0
	p.gravity = Vector3(0, -4, 0)
	p.initial_velocity_min = 2.5
	p.initial_velocity_max = 5.0
	p.scale_amount_min = 0.08
	p.scale_amount_max = 0.18
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 3.0
	p.mesh = BoxMesh.new()
	(p.mesh as BoxMesh).size = Vector3(0.1, 0.1, 0.1)
	p.material_override = m
	var t := p.create_tween()
	t.tween_interval(0.8)
	t.tween_callback(p.queue_free)


# ---------------- area / victory ----------------

func _on_area_entered(id: String) -> void:
	var goal = world_data.get("goal", {})
	if not _won and goal is Dictionary and goal.get("type", "") == "reach_area" and goal.get("target", "") == id:
		_won = true
		_show_victory()


func _show_victory() -> void:
	if victory:
		victory.visible = true
		victory.modulate.a = 0.0
		var t := victory.create_tween()
		t.tween_property(victory, "modulate:a", 1.0, 0.8)


# ---------------- live hot-reload ----------------

func _poll_world() -> void:
	if scene_manager == null or scene_manager.transitioning or world_data.is_empty() or _polling:
		return
	_polling = true
	var req := HTTPRequest.new()
	add_child(req)
	req.request(world_url + "?t=" + str(Time.get_ticks_msec()))
	var res = await req.request_completed
	req.queue_free()
	_polling = false
	if res[1] != 200:
		return
	var raw := (res[3] as PackedByteArray).get_string_from_utf8()
	if raw == _world_raw or raw.strip_edges() == "":
		return
	var w = JSON.parse_string(raw)
	if not (w is Dictionary) or not w.has("areas"):
		return
	_world_raw = raw
	world_data = w
	scene_manager.reload(world_data)


# ---------------- input ----------------

func _input(event: InputEvent) -> void:
	if not started:
		return
	if scene_manager == null or scene_manager.transitioning:
		return
	var half := get_viewport().get_visible_rect().size.x * 0.5
	if event is InputEventScreenTouch:
		if event.pressed and event.position.x < half and move_idx == -1:
			move_idx = event.index
			move_origin = event.position
			move_vec = Vector2.ZERO
		elif not event.pressed and event.index == move_idx:
			move_idx = -1
			move_vec = Vector2.ZERO
	elif event is InputEventScreenDrag and event.index == move_idx:
		move_vec = ((event.position - move_origin) / 90.0).limit_length(1.0)


func _keyboard_vec() -> Vector2:
	var v := Vector2.ZERO
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT): v.x -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT): v.x += 1.0
	if Input.is_physical_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_UP): v.y -= 1.0
	if Input.is_physical_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_DOWN): v.y += 1.0
	if Input.is_action_just_pressed("ui_accept") or Input.is_physical_key_pressed(KEY_J):
		_attack()
	return v


# ---------------- manifest ----------------

func _parse_manifest(body: PackedByteArray) -> void:
	var data = JSON.parse_string(body.get_string_from_utf8())
	var glbs: Array = []
	_collect(data, glbs)
	for s in glbs:
		var u := _norm(s)
		if u != "" and "/godot-assets/props/" in u and "kk_nature" in u:
			props_pool.append(u)


func _collect(v, out_arr: Array) -> void:
	match typeof(v):
		TYPE_STRING:
			if (v as String).to_lower().ends_with(".glb"):
				out_arr.append(v)
		TYPE_DICTIONARY:
			for k in v:
				_collect(v[k], out_arr)
		TYPE_ARRAY:
			for e in v:
				_collect(e, out_arr)


func _norm(s: String) -> String:
	if s.begins_with("http"):
		return s
	if s.begins_with("/"):
		return origin + s
	if "/" in s:
		return origin + "/godot-assets/" + s
	return ""


# ---------------- world build ----------------

func _build_env() -> void:
	var we := WorldEnvironment.new()
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_exposure = 0.82
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.6
	env.fog_enabled = true
	env.fog_light_color = Color(0.7, 0.76, 0.86)
	env.fog_density = 0.01
	sky_day = _make_sky("res://models/sb_cloudy_1.png")
	sky_grey = _make_sky("res://models/sb_cloudy_3.png")
	env.sky = sky_day
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-52, -42, 0)
	sun.light_energy = 1.2
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.directional_shadow_max_distance = 120.0
	add_child(sun)


func _make_sky(path: String) -> Sky:
	var sky := Sky.new()
	var sm := PanoramaSkyMaterial.new()
	var tex = load(path)
	if tex:
		sm.panorama = tex
	sm.energy_multiplier = 0.5
	sky.sky_material = sm
	return sky


func _build_player() -> void:
	player = CharacterBody3D.new()
	player.collision_layer = L_PLAYER
	player.collision_mask = L_WORLD | L_ENEMY | 16   # 16 = DECOR (foliage) so the player bumps it
	add_child(player)
	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.6
	cs.shape = cap
	cs.position.y = 0.85
	player.add_child(cs)

	knight = (load("res://models/kk_Knight.glb") as PackedScene).instantiate() as Node3D
	player.add_child(knight)
	_toonify(knight)
	_apply_outline(knight, 0.022)
	hero_anim = AnimRig.attach(knight, {
		"idle": "Idle_A", "walk": "Walking_A", "run": "Running_A",
		"attack": "Melee_1H_Attack_Slice_Diagonal",
	}, ["idle", "walk", "run"])
	hero_anim.play("idle")

	# sword in the right hand
	var skels := knight.find_children("*", "Skeleton3D", true, false)
	if skels.size() > 0:
		var ba := BoneAttachment3D.new()
		ba.bone_name = "handslot.r"
		(skels[0] as Skeleton3D).add_child(ba)
		var sword := (load("res://models/sword_A.glb") as PackedScene).instantiate() as Node3D
		ba.add_child(sword)
		_apply_outline(sword, 0.02)


func _toonify(root: Node3D) -> void:
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		for s in range(max(1, mi.mesh.get_surface_count())):
			var base: Material = mi.get_active_material(s)
			var m := (base.duplicate() if base else StandardMaterial3D.new()) as StandardMaterial3D
			if m == null:
				continue
			m.diffuse_mode = StandardMaterial3D.DIFFUSE_TOON
			m.specular_mode = StandardMaterial3D.SPECULAR_TOON
			m.roughness = 0.75
			mi.set_surface_override_material(s, m)


func _apply_outline(root: Node3D, width: float) -> void:
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		for s in range(max(1, mi.mesh.get_surface_count())):
			var base: Material = mi.get_active_material(s)
			var mat := (base.duplicate() if base else StandardMaterial3D.new())
			var sh := ShaderMaterial.new()
			sh.shader = OUTLINE_SHADER
			sh.set_shader_parameter("outline", width)
			sh.set_shader_parameter("col", Color(0.05, 0.04, 0.06))
			mat.next_pass = sh
			mi.set_surface_override_material(s, mat)


func _build_camera() -> void:
	cam = Camera3D.new()
	cam.fov = 56.0
	cam.position = CAM_OFFSET
	add_child(cam)


func _update_camera(delta: float) -> void:
	if cam == null or player == null:
		return
	var base := player.global_position + Vector3(0, 1.2, 0)
	var target := base + CAM_OFFSET
	var space := get_world_3d().direct_space_state
	if space:
		var q := PhysicsRayQueryParameters3D.create(base, target, L_WORLD)
		q.exclude = [player.get_rid()]
		var hit := space.intersect_ray(q)
		if hit:
			var hd := maxf(base.distance_to(hit.position as Vector3) - 0.4, 7.0)
			target = base + (target - base).normalized() * hd
	var shake := Vector3.ZERO
	if _shake_t > 0.0:
		_shake_t = max(0.0, _shake_t - delta)
		shake = Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * _shake_t * 0.6
	cam.global_position = cam.global_position.lerp(target, 0.18) + shake
	cam.look_at(base, Vector3.UP)


# ---------------- HUD ----------------

func _build_hud() -> void:
	hud_layer = CanvasLayer.new()
	add_child(hud_layer)

	stats = Label.new()
	stats.add_theme_font_size_override("font_size", 22)
	stats.add_theme_color_override("font_color", Color(0.92, 1.0, 0.92))
	stats.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	stats.add_theme_constant_override("outline_size", 6)
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hud_layer.add_child(stats)

	hp_bg = ColorRect.new()
	hp_bg.color = Color(0, 0, 0, 0.55)
	hp_bg.size = Vector2(300, 22)
	hud_layer.add_child(hp_bg)
	hp_bar = ColorRect.new()
	hp_bar.color = Color(0.85, 0.27, 0.27)
	hp_bar.size = Vector2(300, 22)
	hud_layer.add_child(hp_bar)

	joy_base = _circle(170, Color(1, 1, 1, 0.13))
	hud_layer.add_child(joy_base)
	joy_knob = _circle(78, Color(1, 1, 1, 0.32))
	hud_layer.add_child(joy_knob)

	btn_attack = _button("ATTACK", _attack, Color(0.85, 0.32, 0.28))
	btn_use = _button("USE", func() -> void: interaction.try_use(), Color(0.28, 0.5, 0.82))
	btn_potion = _button("POTION", func() -> void: rpg.use_potion(), Color(0.34, 0.66, 0.4))


func _circle(d: int, col: Color) -> Panel:
	var p := Panel.new()
	p.custom_minimum_size = Vector2(d, d)
	p.size = Vector2(d, d)
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.corner_radius_top_left = d / 2
	sb.corner_radius_top_right = d / 2
	sb.corner_radius_bottom_left = d / 2
	sb.corner_radius_bottom_right = d / 2
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


func _button(text: String, cb: Callable, col: Color) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 30)
	b.add_theme_color_override("font_color", Color(1, 1, 1))
	var sb := StyleBoxFlat.new()
	sb.bg_color = col
	sb.set_corner_radius_all(22)
	b.add_theme_stylebox_override("normal", sb)
	var sb2 := sb.duplicate()
	sb2.bg_color = col.lightened(0.2)
	b.add_theme_stylebox_override("pressed", sb2)
	b.add_theme_stylebox_override("hover", sb)
	b.pressed.connect(cb)
	hud_layer.add_child(b)
	return b


func _update_joystick() -> void:
	if joy_base == null:
		return
	var c := joy_base.position + joy_base.size * 0.5
	joy_knob.position = c + Vector2(move_vec.x, move_vec.y) * 46.0 - joy_knob.size * 0.5
	var active := move_idx != -1 or move_vec.length() > 0.05
	joy_knob.modulate.a = 1.0 if active else 0.6


func _relayout() -> void:
	if hud_layer == null:
		return
	var vp := get_viewport().get_visible_rect().size
	var ml := maxf(16.0, float(insets.get("left", 0)))
	var mt := maxf(14.0, float(insets.get("top", 0)))
	var mr := maxf(16.0, float(insets.get("right", 0)))
	var mb := maxf(20.0, float(insets.get("bottom", 0)))

	hp_bg.position = Vector2(ml, mt)
	hp_bar.position = hp_bg.position
	stats.position = Vector2(ml, mt + 30)
	stats.size.x = maxf(220.0, vp.x - ml - mr)

	var jb := Vector2(ml + 30, vp.y - mb - 200)
	joy_base.position = jb

	var bw := 210.0
	var bh := 116.0
	btn_attack.size = Vector2(bw, bh)
	btn_attack.position = Vector2(vp.x - mr - bw, vp.y - mb - bh)
	btn_use.size = Vector2(bw, 96)
	btn_use.position = Vector2(vp.x - mr - bw, vp.y - mb - bh - 108)
	btn_potion.size = Vector2(180, bh)
	btn_potion.position = Vector2(vp.x - mr - bw - 196, vp.y - mb - bh)

	if victory:
		victory.size = vp
		victory.position = Vector2.ZERO


func _read_insets() -> void:
	if not OS.has_feature("web"):
		return
	var js := """(() => { const d = document.createElement('div');
	  d.style.cssText='position:fixed;top:env(safe-area-inset-top);bottom:env(safe-area-inset-bottom);left:env(safe-area-inset-left);right:env(safe-area-inset-right)';
	  document.body.appendChild(d); const r=getComputedStyle(d);
	  const o={top:parseFloat(r.top)||0,bottom:parseFloat(r.bottom)||0,left:parseFloat(r.left)||0,right:parseFloat(r.right)||0};
	  d.remove(); return JSON.stringify(o); })()"""
	var raw: String = str(JavaScriptBridge.eval(js, true))
	var d = JSON.parse_string(raw) if raw != "" else null
	if d is Dictionary:
		insets = d


# ---------------- tap-to-start overlay ----------------

func _build_overlay() -> void:
	overlay = CanvasLayer.new()
	overlay.layer = 50
	add_child(overlay)
	var bg := ColorRect.new()
	bg.color = Color(0.04, 0.05, 0.08, 0.96)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.add_child(bg)
	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_theme_constant_override("separation", 16)
	bg.add_child(vb)
	var title := Label.new()
	title.text = "HEARTHVALE"
	title.add_theme_font_size_override("font_size", 54)
	title.add_theme_color_override("font_color", Color(0.95, 0.85, 0.55))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(title)
	var sub := Label.new()
	sub.text = "Recover the three keys. Break the seal."
	sub.add_theme_font_size_override("font_size", 24)
	sub.add_theme_color_override("font_color", Color(0.8, 0.85, 0.9))
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(sub)
	var hint := Label.new()
	hint.text = "Drag the LEFT side to move  -  buttons on the RIGHT to act\n(desktop: WASD to move, J to attack)\n\nTAP TO BEGIN"
	hint.add_theme_font_size_override("font_size", 22)
	hint.add_theme_color_override("font_color", Color(0.7, 0.75, 0.82))
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vb.add_child(hint)
	var pulse := hint.create_tween().set_loops()
	pulse.tween_property(hint, "modulate:a", 0.35, 0.7)
	pulse.tween_property(hint, "modulate:a", 1.0, 0.7)
	bg.gui_input.connect(func(e: InputEvent) -> void:
		if (e is InputEventScreenTouch or e is InputEventMouseButton) and e.is_pressed():
			_start_game())

	victory = Control.new()
	victory.set_anchors_preset(Control.PRESET_FULL_RECT)
	victory.mouse_filter = Control.MOUSE_FILTER_STOP
	victory.visible = false
	var vbg := ColorRect.new()
	vbg.color = Color(0.03, 0.04, 0.07, 0.82)
	vbg.set_anchors_preset(Control.PRESET_FULL_RECT)
	victory.add_child(vbg)
	var vv := VBoxContainer.new()
	vv.set_anchors_preset(Control.PRESET_FULL_RECT)
	vv.alignment = BoxContainer.ALIGNMENT_CENTER
	vv.add_theme_constant_override("separation", 16)
	vbg.add_child(vv)
	var vt := Label.new()
	vt.text = "THE SEAL IS BROKEN"
	vt.add_theme_font_size_override("font_size", 48)
	vt.add_theme_color_override("font_color", Color(1.0, 0.86, 0.45))
	vt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vv.add_child(vt)
	var vs := Label.new()
	vs.text = "You reached the Sanctum. Hearthvale is saved!\nTap to keep exploring."
	vs.add_theme_font_size_override("font_size", 26)
	vs.add_theme_color_override("font_color", Color(0.85, 0.9, 0.95))
	vs.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vv.add_child(vs)
	vbg.gui_input.connect(func(e: InputEvent) -> void:
		if (e is InputEventScreenTouch or e is InputEventMouseButton) and e.is_pressed():
			victory.visible = false)
	overlay.add_child(victory)


func _start_game() -> void:
	if started:
		return
	started = true
	if overlay:
		var bg := overlay.get_child(0)
		if bg:
			bg.queue_free()
