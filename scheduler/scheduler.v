module scheduler

import minicoro
import time

pub const default_stack_size = 1 * (1024 * 1024)

pub struct CoroutineManager {
pub mut:
	coroutines []&minicoro.Coro
	current    int
	running    bool
}


pub fn new_manager() CoroutineManager {
	return CoroutineManager{}
}

pub fn (mut m CoroutineManager) add(f fn (&minicoro.Coro)) {
	mut co := minicoro.new()
	mut desc := minicoro.desc_init(f, default_stack_size)
	minicoro.create(&co, &desc)
	m.coroutines << co
}

pub fn (mut m CoroutineManager) switch_coroutine() {
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
	for {
		for m.has_active_coroutines() {
			m.switch_coroutine()
		}
		time.sleep(10 * time.millisecond)
	}
}


pub const default_scheduler = CoroutineManager{}

pub fn go(f fn (&minicoro.Coro)) {
	mut manager := default_scheduler
	if !manager.running {
		manager.running = true
		spawn (&manager).run()
	}
	manager.add(f)
}

