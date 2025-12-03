module scheduler

import minicoro
import vlibuv.uv
import sync

pub const default_stack_size = 1 * (1024 * 1024)

@[heap]
pub struct CoroutineManager {
pub mut:
	coroutines []&minicoro.Coro
	current    int
	running    bool
	loop       &uv.Uv_loop_t
	timer      &uv.Uv_timer_t
	mu         sync.Mutex
}

pub fn new_manager() &CoroutineManager {
	loop := &uv.Uv_loop_t{}
	uv.loop_init(loop)
	timer := &uv.Uv_timer_t{}
	return &CoroutineManager{
		loop:  loop
		timer: timer
	}
}

pub fn (mut m CoroutineManager) add(f fn (&minicoro.Coro)) {
	mut co := minicoro.new()
	mut desc := minicoro.desc_init(f, default_stack_size)
	minicoro.create(&co, &desc)
	m.coroutines << co
}

pub fn (mut m CoroutineManager) switch_coroutine() {
	if m.coroutines.len == 0 {
		return
	}
	current := m.current
	next := (current + 1) % m.coroutines.len
	m.current = next
	minicoro.resume(m.coroutines[next])
}

pub fn (m CoroutineManager) has_active_coroutines() bool {
	for coro in m.coroutines {
		if minicoro.status(coro) != .dead {
			return true
		}
	}
	return false
}

pub fn (mut m CoroutineManager) run() {
	uv.timer_init(m.loop, m.timer)
	m.timer.data = unsafe { &m }
	uv.timer_start(m.timer, schedule_callback, 10, 10)
	uv.run(m.loop, .default)
}

fn schedule_callback(timer &uv.Uv_timer_t) {
	mut manager := unsafe { &CoroutineManager(timer.data) }
	if manager.has_active_coroutines() {
		manager.switch_coroutine()
	}
}

pub const default_scheduler = new_manager()

// Spawn a coroutine
pub fn run(f fn (&minicoro.Coro)) {
	mut manager := default_scheduler
	manager.mu.lock()
	defer { manager.mu.unlock() }

	if !manager.running {
		manager.running = true
		spawn manager.run()
	}
	manager.add(f)
}

// Legacy alias for compatibility
pub fn @go(f fn (&minicoro.Coro)) {
	run(f)
}
