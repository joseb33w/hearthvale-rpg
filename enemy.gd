extends CharacterBody3D
## Enemy: CharacterBody3D + NavigationAgent3D chase with RVO avoidance so enemies ENCIRCLE
## the player (distinct slot angle per index) instead of clumping. Melee w/ cooldown, health,
## death. The streamed skeleton GLBs carry NO embedded clips, so animations are retargeted
## from the shared packed Rig_Medium libraries (AnimRig). On every hit the body flashes white.

var world: Node
var player: Node3D
var anim: AnimationPlayer

var agent: NavigationAgent3D
var mesh_root: Node3D
var _mats: Array = []          # per-instance materials, flashed white on hit

var hp := 45.0
var max_hp := 45.0
var speed := 3.2
var damage := 9.0
var dead := false
var atk_cd := 0.0
var flash_t := 0.0
var busy_t := 0.0              # locked in attack/hit clip until this elapses
var slot_angle := 0.0
var surround_radius := 1.8
var attack_range := 2.1
var kind := "skeleton"
var _cur := ""


func setup(p: Node3D, model: Node, w: Node, index := 0, total := 1, cfg := {}) -> void:
	player = p
	world = w
	collision_layer = 4   # enemy layer
	collision_mask = 1    # world only; RVO avoidance handles enemy separation
	slot_angle = TAU * float(index) / float(max(1, total)) + randf() * 0.3
	kind = String(cfg.get("kind", "skeleton"))
	max_hp = float(cfg.get("hp", 45.0))
	hp = max_hp
	damage = float(cfg.get("damage", 9.0))
	speed = float(cfg.get("speed", 3.2)) + float(index % 3) * 0.25   # desync the blob

	var cs := CollisionShape3D.new()
	var cap := CapsuleShape3D.new()
	cap.radius = 0.4
	cap.height = 1.5
	cs.shape = cap
	cs.position.y = 0.75
	add_child(cs)

	agent = NavigationAgent3D.new()
	agent.radius = 0.55
	agent.height = 1.5
	agent.path_desired_distance = 0.6
	agent.target_desired_distance = 0.4
	agent.avoidance_enabled = true
	agent.neighbor_distance = 4.0
	agent.max_neighbors = 10
	agent.max_speed = speed
	add_child(agent)
	agent.velocity_computed.connect(_on_safe_velocity)

	if model and model is Node3D:
		mesh_root = Node3D.new()
		add_child(mesh_root)
		mesh_root.add_child(model)
		var m3 := model as Node3D
		var sc := float(cfg.get("scale", 1.0))
		m3.scale = Vector3(sc, sc, sc)
		_collect_mats(m3)
		anim = AnimRig.attach(m3, {
			"idle": "Idle_A", "walk": "Walking_A",
			"attack": "Melee_1H_Attack_Chop", "hit": "Hit_A", "death": "Death_A",
		}, ["idle", "walk"])
		anim.seek(randf() * 0.8, true)   # desync idle phase
		_play("idle")
	else:
		var mi := MeshInstance3D.new()
		var cm := CapsuleMesh.new()
		cm.radius = 0.4
		cm.height = 1.5
		mi.mesh = cm
		mi.position.y = 0.75
		var mat := StandardMaterial3D.new()
		mat.albedo_color = Color(0.8, 0.3, 0.3)
		mi.material_override = mat
		add_child(mi)
		mesh_root = mi


func _collect_mats(root: Node3D) -> void:
	for mi: MeshInstance3D in root.find_children("*", "MeshInstance3D", true, false):
		if mi.mesh == null:
			continue
		for s in range(max(1, mi.mesh.get_surface_count())):
			var base: Material = mi.get_active_material(s)
			var m := (base.duplicate() if base else StandardMaterial3D.new()) as StandardMaterial3D
			if m == null:
				continue
			mi.set_surface_override_material(s, m)
			_mats.append(m)


func _physics_process(delta: float) -> void:
	if dead or not is_instance_valid(player):
		return
	atk_cd = max(0.0, atk_cd - delta)
	busy_t = max(0.0, busy_t - delta)
	if flash_t > 0.0:
		flash_t = max(0.0, flash_t - delta)
		_apply_flash(flash_t / 0.14)

	var ppos: Vector3 = player.global_position
	var to: Vector3 = ppos - global_position
	to.y = 0.0
	var dist := to.length()
	var desired := Vector3.ZERO

	if dist <= attack_range and atk_cd <= 0.0:
		atk_cd = 1.3
		busy_t = 0.55
		_play("attack", false, true)
		if player.has_method("take_damage"):
			player.call("take_damage", damage)

	var slot := ppos + Vector3(cos(slot_angle), 0.0, sin(slot_angle)) * surround_radius
	agent.target_position = slot
	var next := agent.get_next_path_position()
	var dir := next - global_position
	dir.y = 0.0
	if dir.length() < 0.05:
		dir = slot - global_position
		dir.y = 0.0
	_face(to)
	if busy_t <= 0.0:
		if dir.length() > 0.2 and dist > attack_range * 0.8:
			desired = dir.normalized() * speed
			_play("walk")
		else:
			_play("idle")

	agent.set_velocity(desired)


func _on_safe_velocity(safe: Vector3) -> void:
	if dead:
		return
	velocity = Vector3(safe.x, 0.0, safe.z)
	move_and_slide()


func take_hit(d: float) -> void:
	if dead:
		return
	hp -= d
	flash_t = 0.14
	if hp <= 0.0:
		_die()
	elif busy_t <= 0.0:
		busy_t = 0.35
		_play("hit", false, true)


func _die() -> void:
	dead = true
	velocity = Vector3.ZERO
	collision_layer = 0
	collision_mask = 0
	_apply_flash(0.0)
	if is_instance_valid(world) and world.has_method("on_enemy_killed"):
		world.on_enemy_killed(kind)
	_play("death", false, true)
	var t := create_tween()
	t.tween_interval(1.2)
	t.tween_property(self, "position:y", -2.0, 0.6)
	t.tween_callback(queue_free)


# ---------------- visuals ----------------

func _apply_flash(amount: float) -> void:
	for m: StandardMaterial3D in _mats:
		if amount > 0.001:
			m.emission_enabled = true
			m.emission = Color(1, 1, 1)
			m.emission_energy_multiplier = amount * 6.0
		else:
			m.emission_energy_multiplier = 0.0


func _play(alias: String, loop := true, restart := false) -> void:
	if anim == null or alias == "":
		return
	if _cur == alias and not restart:
		return
	_cur = alias
	if anim.has_animation(alias):
		anim.play(alias)
		if restart:
			anim.seek(0.0, true)


func _face(dir: Vector3) -> void:
	if dir.length() < 0.05:
		return
	var look := global_position - Vector3(dir.x, 0.0, dir.z)
	look_at(Vector3(look.x, global_position.y, look.z), Vector3.UP)
