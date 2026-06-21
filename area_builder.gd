class_name AreaBuilder extends Node
## AREA BUILDER — turns one world.json area RECORD into a live, themed scene: streams its .glb
## from R2 (parallel, behind the fade), lays a procedural-noise ground, places per-area KIT
## buildings/landmarks (with derived rotated colliders), scatters themed dressing, lights
## torches, spawns typed enemies, applies the per-area MOOD (sky/sun/fog/ambient), and bakes
## nav. The .pck binds scripts+shaders+hero+sky; everything else streams from R2 at runtime.

const OUTLINE_SHADER := preload("res://shaders/outline.gdshader")

const ENEMY_MODELS := {
	"minion": "enemies/skeleton_minion.glb",
	"warrior": "enemies/skeleton_warrior.glb",
	"rogue": "enemies/skeleton_rogue.glb",
	"mage": "enemies/skeleton_mage.glb",
	"skeleton": "enemies/skeleton_warrior.glb",
}
const ENEMY_CFG := {
	"minion": {"hp": 32.0, "damage": 6.0, "speed": 3.5, "scale": 0.85},
	"warrior": {"hp": 62.0, "damage": 11.0, "speed": 2.9, "scale": 1.0},
	"rogue": {"hp": 46.0, "damage": 9.0, "speed": 3.8, "scale": 0.95},
	"mage": {"hp": 52.0, "damage": 13.0, "speed": 2.7, "scale": 1.0},
}
const NPC_DEFAULT := "characters/kk_Mage.glb"
const CHEST_MODEL := "props/kk_dungeon/chest_gold.glb"

const PALETTE := {
	"tree": "props/kk_nature/Tree_2_A_Color1.glb",
	"tree2": "props/kk_nature/Tree_3_A_Color1.glb",
	"pine": "props/kk_nature/Tree_4_A_Color1.glb",
	"bare": "props/kk_nature/Tree_Bare_1_A_Color1.glb",
	"rock": "props/kk_nature/Rock_1_C_Color1.glb",
	"rock2": "props/kk_nature/Rock_1_J_Color1.glb",
	"bush": "props/kk_nature/Bush_2_A_Color1.glb",
	"grass": "props/kk_nature/Grass_2_A_Color1.glb",
	"torch": "props/kk_dungeon/torch_lit.glb",
	"column": "props/kk_dungeon/column.glb",
	"pillar": "props/kk_dungeon/pillar.glb",
	"banner": "props/kk_dungeon/banner_blue.glb",
	"well": "props/kk_hex/building_well_blue.glb",
	"key": "props/kk_dungeon/key.glb",
}

var origin: String
var cache := {}                     # url -> source Node (persists across areas)
var props_pool: Array = []
var env: Environment
var sun: DirectionalLight3D
var sky_day: Sky
var sky_grey: Sky
var _pending := 0


func build_area(rec: Dictionary, scene_parent: Node, player: Node3D, world_main: Node,
		interaction, _rpg) -> Dictionary:
	var size := float(rec.get("size", 14))
	var enemy_n := int(rec.get("enemies", 0))
	var enemy_type := String(rec.get("enemy_type", "warrior"))
	var scatter_n := int(rec.get("scatter", 0))

	# ---- 1. resolve every URL this area needs, download missing ones in PARALLEL ----
	var urls: Array = []
	var _add := func(u: String) -> void:
		if u != "" and not (u in urls):
			urls.append(u)

	if enemy_n > 0:
		_add.call(_full(ENEMY_MODELS.get(enemy_type, ENEMY_MODELS["warrior"])))
	if rec.has("npc"):
		_add.call(_full(String((rec.npc as Dictionary).get("model", NPC_DEFAULT))))
	if rec.has("chest"):
		_add.call(_full(CHEST_MODEL))

	var scatter_set: Array = rec.get("scatter_set", [])
	var chosen: Array = []
	for _i in range(scatter_n):
		var pick := ""
		if not scatter_set.is_empty():
			pick = _full(String(scatter_set[randi() % scatter_set.size()]))
		elif not props_pool.is_empty():
			pick = String(props_pool[randi() % props_pool.size()])
		if pick != "":
			chosen.append(pick)
			_add.call(pick)

	var kit: Array = rec.get("kit", [])
	for k in kit:
		_add.call(_full(String((k as Dictionary).get("model", ""))))

	var named: Array = rec.get("props", [])
	for np in named:
		_add.call(_palette_url(np))

	var torches: Array = rec.get("torches", [])
	if not torches.is_empty():
		_add.call(_full(PALETTE["torch"]))

	await _ensure(urls)

	# ---- 2. mood + room ----
	_apply_mood(rec)
	var root := Node3D.new()
	scene_parent.add_child(root)
	var nav := _build_room(root, size, rec)

	# ---- 3. KIT (specific buildings / landmarks) ----
	for k in kit:
		var kd := k as Dictionary
		var url := _full(String(kd.get("model", "")))
		if not cache.has(url):
			continue
		var m := (cache[url] as Node).duplicate() as Node3D
		root.add_child(m)
		var p = kd.get("pos", [0, 0, 0])
		var scl := float(kd.get("scale", 1.0))
		m.position = Vector3(float(p[0]), float(p[1]), float(p[2]))
		m.rotation_degrees.y = float(kd.get("yaw", 0.0))
		m.scale = Vector3(scl, scl, scl)
		if bool(kd.get("collide", true)):
			_add_box_collider(m, root)
		if bool(kd.get("outline", false)):
			apply_outline(m, 0.03)

	# ---- 4. SCATTER dressing (kept clear of spawns/seams + the LANES between them so
	#         foliage never walls the path from a spawn to a seam or the chest) ----
	var clear_pts: Array = []
	var spawn_pts: Array = []
	for sp in (rec.get("spawns", {}) as Dictionary).values():
		var spv := Vector3(float(sp[0]), 0.0, float(sp[2]))
		spawn_pts.append(spv)
		clear_pts.append(spv)
	var goal_pts: Array = []
	for sm in rec.get("seams", []):
		var spp = (sm as Dictionary).get("pos", [0, 0, 0])
		var smv := Vector3(float(spp[0]), 0.0, float(spp[2]))
		goal_pts.append(smv)
		clear_pts.append(smv)
	if rec.has("chest"):
		var cp = (rec.chest as Dictionary).get("pos", [0, 0, 0])
		var chv := Vector3(float(cp[0]), 0.0, float(cp[2]))
		goal_pts.append(chv)
		clear_pts.append(chv)
	var lanes: Array = []            # spawn -> (each seam + chest): keep a walkable corridor
	for a in spawn_pts:
		for b in goal_pts:
			lanes.append([a, b])
	for u in chosen:
		if not cache.has(u):
			continue
		var p := (cache[u] as Node).duplicate() as Node3D
		root.add_child(p)
		var pos := Vector3.ZERO
		for _try in range(14):
			var ang := randf() * TAU
			var rad := randf_range(size * 0.2, size - 1.5)
			pos = Vector3(cos(ang) * rad, 0.0, sin(ang) * rad)
			var ok := true
			for cp in clear_pts:
				if pos.distance_to(cp) < 5.0:
					ok = false
					break
			if ok:
				for ln in lanes:
					if _dist_to_seg(pos, ln[0], ln[1]) < 3.0:
						ok = false
						break
			if ok:
				break
		p.position = pos
		p.rotation.y = randf() * TAU
		var s := randf_range(0.8, 1.35)
		p.scale = Vector3(s, s, s)
		var ab := _world_aabb(p)
		var maxdim: float = max(ab.size.x, max(ab.size.y, ab.size.z))
		if maxdim > 4.5:
			var sc: float = 4.5 / maxdim
			p.scale *= sc
		_add_prop_collision(p, root)

	# ---- 5. named palette props ----
	for np in named:
		var purl := _palette_url(np)
		if purl == "" or not cache.has(purl):
			continue
		var n := (cache[purl] as Node).duplicate() as Node3D
		root.add_child(n)
		var pos = (np as Dictionary).get("pos", [0, 0, 0])
		n.position = Vector3(clamp(float(pos[0]), -size + 1.0, size - 1.0), float(pos[1]),
			clamp(float(pos[2]), -size + 1.0, size - 1.0))
		n.rotation_degrees.y = float((np as Dictionary).get("yaw", randf() * 360.0))
		_add_prop_collision(n, root)

	# ---- 6. torches with light ----
	for t in torches:
		_place_torch(root, (t as Dictionary).get("pos", [0, 0, 0]))

	# ---- 7. enemies (typed) ----
	var enemies: Array = []
	var emodel_url := _full(ENEMY_MODELS.get(enemy_type, ENEMY_MODELS["warrior"]))
	if enemy_n > 0 and cache.has(emodel_url):
		var cfg: Dictionary = ENEMY_CFG.get(enemy_type, ENEMY_CFG["warrior"])
		var ring := float(rec.get("enemy_ring", size * 0.42))
		for i in range(enemy_n):
			var e := CharacterBody3D.new()
			e.set_script(load("res://enemy.gd"))
			root.add_child(e)
			var ang := TAU * float(i) / float(enemy_n) + 0.3
			e.global_position = Vector3(cos(ang) * ring, 0.0, sin(ang) * ring)
			var ecfg := cfg.duplicate()
			ecfg["kind"] = enemy_type
			e.setup(player, (cache[emodel_url] as Node).duplicate(), world_main, i, enemy_n, ecfg)
			enemies.append(e)

	nav.bake_navigation_mesh(false)

	# ---- 8. interactables ----
	interaction.set_area_parent(root)
	if rec.has("chest"):
		var c := rec.chest as Dictionary
		var cm: Node = (cache[_full(CHEST_MODEL)] as Node).duplicate() if cache.has(_full(CHEST_MODEL)) else null
		interaction.add_chest(_v3(c.pos), c.get("contents", []), int(c.get("gold", 0)), cm)
	if rec.has("npc"):
		var npc := rec.npc as Dictionary
		var nurl := _full(String(npc.get("model", NPC_DEFAULT)))
		var model: Node = (cache[nurl] as Node).duplicate() if cache.has(nurl) else null
		interaction.add_npc(_v3(npc.pos), String(npc.get("id", "")), npc.name, npc.persona, npc.lines, model)
	for s in rec.get("seams", []):
		var sd := s as Dictionary
		var lk := String(sd.get("requires", sd.get("lock", "")))
		interaction.add_seam(_v3(sd.pos), sd.to, sd.spawn, lk, sd.get("label", "Door"), String(sd.get("hint", "")))

	return {root = root, enemies = enemies}


# ---------------- mood ----------------

func _apply_mood(rec: Dictionary) -> void:
	if env == null:
		return
	var sky_id := String(rec.get("sky", "day"))
	var amb = rec.get("ambient", [0.6, 0.6, 0.66])
	env.ambient_light_color = Color(amb[0], amb[1], amb[2])
	env.fog_enabled = true
	var fog = rec.get("fog", [0.62, 0.68, 0.78])
	env.fog_light_color = Color(fog[0], fog[1], fog[2])
	env.fog_density = float(rec.get("fog_density", 0.01))
	if sky_id == "dark":
		env.background_mode = Environment.BG_COLOR
		var bg = rec.get("bg", [0.02, 0.02, 0.035])
		env.background_color = Color(bg[0], bg[1], bg[2])
		env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		if sun:
			sun.light_energy = float(rec.get("sun_energy", 0.16))
			sun.light_color = Color(0.55, 0.62, 0.85)
	else:
		env.background_mode = Environment.BG_SKY
		env.sky = sky_grey if sky_id == "grey" else sky_day
		env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
		if sun:
			sun.light_energy = float(rec.get("sun_energy", 1.2))
			var sc = rec.get("sun_color", [1.0, 0.95, 0.86])
			sun.light_color = Color(sc[0], sc[1], sc[2])
	if sun:
		var sa = rec.get("sun_angle", [-52, -42])
		sun.rotation_degrees = Vector3(float(sa[0]), float(sa[1]), 0.0)


# ---------------- parallel download ----------------

func _ensure(urls: Array) -> void:
	_pending = 0
	for u in urls:
		if cache.has(u):
			continue
		_pending += 1
		var req := HTTPRequest.new()
		add_child(req)
		req.request_completed.connect(_on_dl.bind(u, req))
		req.request(u)
	var guard := 0
	while _pending > 0 and guard < 2400:
		await get_tree().process_frame
		guard += 1


func _on_dl(result: int, code: int, _h: PackedStringArray, body: PackedByteArray, url: String, req: HTTPRequest) -> void:
	if result == HTTPRequest.RESULT_SUCCESS and code == 200 and body.size() > 0:
		var doc := GLTFDocument.new()
		var st := GLTFState.new()
		if doc.append_from_buffer(body, "", st) == OK:
			cache[url] = doc.generate_scene(st)
	req.queue_free()
	_pending -= 1


# ---------------- build helpers ----------------

func _build_room(root: Node, size: float, rec: Dictionary) -> NavigationRegion3D:
	var nav := NavigationRegion3D.new()
	var nm := NavigationMesh.new()
	nm.agent_radius = 0.5
	nm.agent_height = 1.75
	nm.cell_size = 0.25
	nm.cell_height = 0.25
	nm.geometry_parsed_geometry_type = NavigationMesh.PARSED_GEOMETRY_STATIC_COLLIDERS
	nav.navigation_mesh = nm
	root.add_child(nav)

	var gc = rec.get("ground", [0.3, 0.33, 0.38])
	var base := Color(gc[0], gc[1], gc[2])
	var gmat := _ground_mat(base.darkened(0.22), base.lightened(0.14), float(rec.get("ground_rough", 0.92)))
	var ground := StaticBody3D.new()
	ground.collision_layer = 1
	ground.position = Vector3(0, -0.5, 0)
	var gmi := MeshInstance3D.new()
	var gbm := BoxMesh.new()
	gbm.size = Vector3(size * 2.0, 1.0, size * 2.0)
	gmi.mesh = gbm
	gmi.material_override = gmat
	ground.add_child(gmi)
	var gcs := CollisionShape3D.new()
	var gbs := BoxShape3D.new()
	gbs.size = gbm.size
	gcs.shape = gbs
	ground.add_child(gcs)
	nav.add_child(ground)

	var wall := base.darkened(0.5)
	var wh := float(rec.get("wall_h", 5.0))
	_box(nav, Vector3(0, wh * 0.5 - 0.4, -size), Vector3(size * 2, wh, 1), wall)
	_box(nav, Vector3(0, wh * 0.5 - 0.4, size), Vector3(size * 2, wh, 1), wall)
	_box(nav, Vector3(-size, wh * 0.5 - 0.4, 0), Vector3(1, wh, size * 2), wall)
	_box(nav, Vector3(size, wh * 0.5 - 0.4, 0), Vector3(1, wh, size * 2), wall)
	return nav


func _ground_mat(c1: Color, c2: Color, rough: float) -> StandardMaterial3D:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = 0.035
	var img := n.get_image(128, 128, false, false, false)   # grayscale, synchronous
	img.convert(Image.FORMAT_RGB8)
	for y in range(128):
		for x in range(128):
			var l := img.get_pixel(x, y).r
			img.set_pixel(x, y, c1.lerp(c2, l))
	var tex := ImageTexture.create_from_image(img)
	var m := StandardMaterial3D.new()
	m.albedo_texture = tex
	m.uv1_triplanar = true
	m.uv1_scale = Vector3(0.32, 0.32, 0.32)
	m.roughness = rough
	m.metallic = 0.0
	return m


func _place_torch(parent: Node, pos) -> void:
	var p := Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	var url := _full(PALETTE["torch"])
	if cache.has(url):
		var m := (cache[url] as Node).duplicate() as Node3D
		m.position = p
		parent.add_child(m)
	var light := OmniLight3D.new()
	light.position = p + Vector3(0, 2.0, 0)
	light.light_color = Color(1.0, 0.72, 0.4)
	light.light_energy = 2.6
	light.omni_range = 9.0
	light.shadow_enabled = false
	parent.add_child(light)
	var fl := light.create_tween().set_loops()
	fl.tween_property(light, "light_energy", 2.0, 0.12)
	fl.tween_property(light, "light_energy", 3.0, 0.16)
	fl.tween_property(light, "light_energy", 2.5, 0.1)


func _box(parent: Node, pos: Vector3, sz: Vector3, col: Color) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = 1
	body.position = pos
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
	parent.add_child(body)


func _add_box_collider(model: Node3D, parent: Node) -> void:
	var ab := _rel_aabb(model)
	if ab.size.x < 0.05 and ab.size.z < 0.05:
		return
	var body := StaticBody3D.new()
	body.collision_layer = 1
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(max(ab.size.x, 0.2), max(ab.size.y, 0.4), max(ab.size.z, 0.2)) * model.scale.x
	cs.shape = box
	cs.position = ab.get_center() * model.scale.x
	body.add_child(cs)
	parent.add_child(body)
	body.global_position = model.global_position
	body.rotation = model.rotation


func _add_prop_collision(prop: Node3D, parent: Node) -> void:
	var aabb := _world_aabb(prop)
	if aabb.size.x < 0.18 and aabb.size.z < 0.18:
		return
	var body := StaticBody3D.new()
	body.collision_layer = 16   # DECOR layer: player bumps it, but the camera ray ignores it
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(clamp(aabb.size.x, 0.2, 2.2), max(aabb.size.y, 0.4), clamp(aabb.size.z, 0.2, 2.2))
	cs.shape = box
	body.add_child(cs)
	parent.add_child(body)
	body.global_position = aabb.position + aabb.size * 0.5


func _rel_aabb(model: Node3D) -> AABB:
	var inv := model.global_transform.affine_inverse()
	var merged := AABB()
	var first := true
	for mi: MeshInstance3D in model.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		var t := inv * mi.global_transform
		var a: AABB = t * mi.get_aabb()
		if first:
			merged = a
			first = false
		else:
			merged = merged.merge(a)
	return merged


func _world_aabb(root: Node3D) -> AABB:
	var merged := AABB()
	var first := true
	var stack: Array = [root]
	while not stack.is_empty():
		var n = stack.pop_back()
		for c in n.get_children():
			stack.append(c)
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var mi := n as MeshInstance3D
			var wa: AABB = mi.global_transform * mi.get_aabb()
			if first:
				merged = wa
				first = false
			else:
				merged = merged.merge(wa)
	return merged


func apply_outline(root: Node3D, width: float = 0.03, color: Color = Color(0.04, 0.03, 0.05)) -> void:
	for m: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if m.mesh == null:
			continue
		for s in range(max(1, m.mesh.get_surface_count())):
			var base: Material = m.get_active_material(s)
			var mat := (base.duplicate() if base else StandardMaterial3D.new())
			var sh := ShaderMaterial.new()
			sh.shader = OUTLINE_SHADER
			sh.set_shader_parameter("outline", width)
			sh.set_shader_parameter("col", color)
			mat.next_pass = sh
			m.set_surface_override_material(s, mat)


func _palette_url(np) -> String:
	if typeof(np) != TYPE_DICTIONARY:
		return ""
	var kind := String((np as Dictionary).get("kind", "")).to_lower().strip_edges()
	return _full(PALETTE[kind]) if PALETTE.has(kind) else ""


func _full(path: String) -> String:
	if path == "":
		return ""
	if path.begins_with("http"):
		return path
	if path.begins_with("/"):
		return origin + path
	return origin + "/godot-assets/" + path


func _v3(a) -> Vector3:
	return Vector3(a[0], a[1], a[2])


func _dist_to_seg(p: Vector3, a: Vector3, b: Vector3) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 0.95
	return m
