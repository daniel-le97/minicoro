@[translated]
module minicoro

$if debug {
	#define MCO_DEBUG
}

#define MINICORO_IMPL
#flag -I @VMODROOT/
#include "minicoro.h"
// #include "sp_corrector.c"

// fn C.sp_corrector(voidptr, voidptr)

fn init() {
	$if gcboehm ? {
		// NOTE `sp_corrector` only works for platforms with the stack growing down
		// MacOs, Win32 and Linux always have stack growing down.
		// A proper solution is planned (hopefully) for boehm v8.4.0.
		// C.GC_set_sp_corrector(C.sp_corrector)
		// if C.GC_get_sp_corrector() == unsafe { nil } {
		// 	panic('stack pointer correction unsupported')
		// }
	}
}

pub enum State {
	dead = 0
	normal
	running
	suspended
}

pub enum Result {
	success = 0
	generic_error
	invalid_pointer
	invalid_coroutine
	not_suspended
	not_running
	make_context_error
	switch_context_error
	not_enough_space
	out_of_memory
	invalid_arguments
	invalid_operation
	stack_overflow
}

pub type CoroFN = fn (&Coro)

@[typedef]
pub struct C.mco_coro {
pub mut:
	context         voidptr
	state           int    // You'll need to create an enum or use an int type to match `mco_state`
	func            CoroFN // Function pointer that matches the signature
	prev_co         &C.mco_coro
	user_data       voidptr
	coro_size       usize
	allocator_data  voidptr
	dealloc_cb      fn (voidptr, usize, voidptr)
	stack_base      voidptr
	stack_size      usize
	storage         &u8 // Pointer to unsigned char
	bytes_stored    usize
	storage_size    usize
	asan_prev_stack voidptr
	tsan_prev_fiber voidptr
	tsan_fiber      voidptr
	magic_number    usize
}

pub type Coro = C.mco_coro

pub type Desc = C.mco_desc

@[typedef]
pub struct C.mco_desc {
pub mut:
	func           CoroFN
	user_data      voidptr
	alloc_cb       fn (usize, voidptr) voidptr
	dealloc_cb     fn (voidptr, usize, voidptr)
	allocator_data voidptr
	storage_size   usize
	coro_size      usize
	stack_size     usize
}

fn alloc(stack_size usize, ptr voidptr) voidptr {
	unsafe {
		stack_ptr := vcalloc(stack_size)
		$if gcboehm ? {
			C.GC_add_roots(stack_ptr, charptr(stack_ptr) + stack_size)
		}
		return stack_ptr
	}
}

fn dealloc(ptr voidptr, stack_size usize, stack_ptr voidptr) {
	unsafe {
		$if gcboehm ? {
			C.GC_remove_roots(stack_ptr, charptr(stack_ptr) + stack_size)
		}
		free(stack_ptr)
	}
}

pub fn new() &Coro {
	return &Coro{}
}

fn C.mco_desc_init(func CoroFN, stack_size usize) Desc

pub fn desc_init(func CoroFN, stack_size usize) Desc {
	mut desc := C.mco_desc_init(func, stack_size)
	desc.alloc_cb = alloc
	desc.dealloc_cb = dealloc
	return desc
}

fn C.mco_init(co &Coro, desc &Desc) Result

pub fn coro_init(co &Coro, desc &Desc) Result {
	return C.mco_init(co, desc)
}

fn C.mco_uninit(co &Coro) Result

pub fn coro_uninit(co &Coro) Result {
	return C.mco_uninit(co)
}

fn C.mco_create(out_co &&Coro, desc &Desc) Result

pub fn create(out_co &&Coro, desc &Desc) Result {
	return C.mco_create(out_co, desc)
}

fn C.mco_destroy(co &Coro) Result

pub fn destroy(co &Coro) Result {
	return C.mco_destroy(co)
}

fn C.mco_resume(co &Coro) Result

pub fn resume(co &Coro) Result {
	return C.mco_resume(co)
}

fn C.mco_yield(co &Coro) Result

pub fn yield(co &Coro) Result {
	return C.mco_yield(co)
}

fn C.mco_status(co &Coro) State

pub fn status(co &Coro) State {
	return C.mco_status(co)
}

fn C.mco_get_user_data(co &Coro) voidptr

pub fn get_user_data(co &Coro) voidptr {
	return C.mco_get_user_data(co)
}

fn C.mco_push(co &Coro, src voidptr, len usize) Result

pub fn push(co &Coro, src voidptr, len usize) Result {
	return C.mco_push(co, src, len)
}

fn C.mco_pop(co &Coro, dest voidptr, len usize) Result

pub fn pop(co &Coro, dest voidptr, len usize) Result {
	return C.mco_pop(co, dest, len)
}

fn C.mco_peek(co &Coro, dest voidptr, len usize) Result

pub fn peek(co &Coro, dest voidptr, len usize) Result {
	return C.mco_peek(co, dest, len)
}

fn C.mco_get_bytes_stored(co &Coro) usize

pub fn get_bytes_stored(co &Coro) usize {
	return C.mco_get_bytes_stored(co)
}

fn C.mco_get_storage_size(co &Coro) usize

pub fn get_storage_size(co &Coro) usize {
	return C.mco_get_storage_size(co)
}

fn C.mco_running() &Coro

pub fn running() &Coro {
	return C.mco_running()
}

fn C.mco_result_description(res Result) &char

pub fn result_description(res Result) &char {
	return C.mco_result_description(res)
}
