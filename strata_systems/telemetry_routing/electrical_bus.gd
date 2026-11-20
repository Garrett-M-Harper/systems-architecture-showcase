class_name ElectricalBus
extends Node

## Monitors combined electrical draw from all mech subsystems.
## When combined draw exceeds the bus limit (default 50A), trips the highest-draw
## subsystem's breaker and emits a system alert.

@export var bus_limit_amps: float = 50.0

var _consumers: Dictionary = {}
var _cooldown: float = 0.0

signal breaker_tripped(consumer_name: String)

func register_consumer(consumer_name: String, amps: float) -> void:
	if amps <= 0.0:
		deregister_consumer(consumer_name)
	else:
		_consumers[consumer_name] = amps

func deregister_consumer(consumer_name: String) -> void:
	_consumers.erase(consumer_name)

func get_total_draw() -> float:
	var total: float = 0.0
	for amps in _consumers.values():
		total += amps
	return total

func _process(delta: float) -> void:
	if _cooldown > 0.0:
		_cooldown -= delta

	var total = get_total_draw()
	if total > bus_limit_amps and _cooldown <= 0.0:
		_trip_breaker()

var _tripped_consumers: Dictionary = {} # consumer_name -> original amps

func _trip_breaker() -> void:
	var highest_name: String = ""
	var highest_draw: float = -1.0

	for c_name in _consumers:
		var draw: float = _consumers[c_name]
		if draw > highest_draw:
			highest_draw = draw
			highest_name = c_name

	if highest_name != "":
		_tripped_consumers[highest_name] = _consumers[highest_name]
		_consumers.erase(highest_name)
		_cooldown = 0.5

		var bus = get_node_or_null("/root/GameEventBus")
		if bus and bus.has_signal("system_alert"):
			bus.system_alert.emit("BUS_FAULT: " + highest_name + " TRIPPED", "WARN")

		breaker_tripped.emit(highest_name)

func reset_breaker(consumer_name: String) -> void:
	if _tripped_consumers.has(consumer_name):
		_consumers[consumer_name] = _tripped_consumers[consumer_name]
		_tripped_consumers.erase(consumer_name)

func is_tripped(consumer_name: String) -> bool:
	return _tripped_consumers.has(consumer_name)
