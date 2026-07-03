extends RefCounted
## Procedural audio: synthesizes all game sounds as PCM at boot (no asset files).
## Loops: wind / waves / rain / interior hum / underwater. One-shots: pops, chimes,
## whooshes, thuds.

const RATE := 22050

static func _to_wav(samples: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(samples.size() * 2)
	for i in samples.size():
		var v := int(clampf(samples[i], -1.0, 1.0) * 32000.0)
		bytes.encode_s16(i * 2, v)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.data = bytes
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_end = samples.size()
	return wav

## Looping filtered noise. lowpass 0..1 (small = darker/rumblier). Crossfaded seam.
static func noise_loop(dur: float, lowpass: float, gain: float, noise_seed: int) -> AudioStreamWAV:
	var n := int(dur * RATE)
	var rng := RandomNumberGenerator.new()
	rng.seed = noise_seed
	var s := PackedFloat32Array()
	s.resize(n)
	var y := 0.0
	var y2 := 0.0
	for i in n:
		var x := rng.randf_range(-1.0, 1.0)
		y += lowpass * (x - y)
		y2 += lowpass * (y - y2)     # second pole = smoother rumble
		s[i] = y2 * gain
	# blend the tail into the head so the loop is seamless
	var fade := int(0.1 * RATE)
	for i in fade:
		var t := float(i) / fade
		s[n - fade + i] = lerpf(s[n - fade + i], s[i] * t, t)
	return _to_wav(s, true)

## Waves: dark noise swelling twice per loop (period-locked so the loop is clean).
static func waves_loop() -> AudioStreamWAV:
	var dur := 8.0
	var n := int(dur * RATE)
	var rng := RandomNumberGenerator.new()
	rng.seed = 777
	var s := PackedFloat32Array()
	s.resize(n)
	var y := 0.0
	for i in n:
		var t := float(i) / RATE
		var env := 0.3 + 0.7 * pow(sin(PI * t / 4.0), 2.0)
		y += 0.045 * (rng.randf_range(-1.0, 1.0) - y)
		s[i] = y * env * 2.6
	return _to_wav(s, true)

## Interior hum: soft low drone (two detuned sines + slow tremolo), loop-exact.
static func hum_loop() -> AudioStreamWAV:
	var dur := 4.0
	var n := int(dur * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE
		var trem := 0.75 + 0.25 * sin(TAU * t / 2.0)
		s[i] = (sin(TAU * 55.0 * t) * 0.5 + sin(TAU * 82.5 * t) * 0.3) * 0.16 * trem
	return _to_wav(s, true)

## Short pitch-sweep pop (harvest hits, breaks).
static func pop(f0: float, f1: float, dur: float, gain: float) -> AudioStreamWAV:
	var n := int(dur * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	var phase := 0.0
	for i in n:
		var t := float(i) / n
		var f := lerpf(f0, f1, t)
		phase += TAU * f / RATE
		s[i] = sin(phase) * gain * exp(-4.5 * t)
	return _to_wav(s, false)

## Gentle two-note chime (crafting, planting, refining).
static func chime(fa: float, fb: float) -> AudioStreamWAV:
	var dur := 0.5
	var n := int(dur * RATE)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE
		var a := sin(TAU * fa * t) * exp(-6.0 * t)
		var b := sin(TAU * fb * maxf(t - 0.12, 0.0)) * exp(-6.0 * maxf(t - 0.12, 0.0)) * float(t > 0.12)
		s[i] = (a * 0.5 + b * 0.5) * 0.5
	return _to_wav(s, false)

## Organic growth whoosh: swelling dark noise over a low sine.
static func whoosh() -> AudioStreamWAV:
	var dur := 0.9
	var n := int(dur * RATE)
	var rng := RandomNumberGenerator.new()
	rng.seed = 31
	var s := PackedFloat32Array()
	s.resize(n)
	var y := 0.0
	for i in n:
		var t := float(i) / n
		var env := pow(sin(PI * t), 1.5)
		y += 0.10 * (rng.randf_range(-1.0, 1.0) - y)
		s[i] = (y * 2.0 + sin(TAU * 70.0 * t * dur) * 0.3) * env * 0.7
	return _to_wav(s, false)

## Meteor thud: deep sine drop + noise burst.
static func thud() -> AudioStreamWAV:
	var dur := 0.5
	var n := int(dur * RATE)
	var rng := RandomNumberGenerator.new()
	rng.seed = 99
	var s := PackedFloat32Array()
	s.resize(n)
	var phase := 0.0
	var y := 0.0
	for i in n:
		var t := float(i) / n
		phase += TAU * lerpf(85.0, 38.0, t) / RATE
		y += 0.3 * (rng.randf_range(-1.0, 1.0) - y)
		s[i] = (sin(phase) * 0.8 + y * 0.5 * exp(-9.0 * t)) * exp(-3.5 * t)
	return _to_wav(s, false)
