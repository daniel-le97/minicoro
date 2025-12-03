module main

import scheduler {@go}
import minicoro
import time

fn coro_fn(co &minicoro.Coro) {
	println('coro 1 before')
	for {
		println('coro1')
		minicoro.yield(co)
		println('coro after')
	}
}

fn coro_fn2(co &minicoro.Coro) {
	println('coro 2 before')
	for {
		println('coro2')
		minicoro.yield(co)
		println('coro 2 after')
	}
}

fn main() {
	defer {
		println('main done')
	}
	println('Coroutine Example')
	@go(coro_fn)
	@go(coro_fn2)

	println('sleeping for 1 second')
	time.sleep(1 * time.second)
}
