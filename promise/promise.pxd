from asyncio import Future

from .schedulers cimport SchedulerFn, Scheduler


cdef enum State:
    PENDING, REJECTED, FULFILLED


cdef class Promise:
    cdef public State _state
    cdef public bint _is_following, _is_async_guaranteed

    cdef bint _is_final, _is_bound, _is_waiting
    cdef int _length

    cdef list _promises, _rejection_handlers, _fulfillment_handlers
    cdef Promise _promise0
    cdef object _future, _fulfillment_handler0, _rejection_handler0, _scheduler

    cpdef Scheduler get_scheduler(self)
    cpdef object get_future(self)

    cdef void _resolve_callback(self, object value)
    cdef object _settled_value(self, bint raise_=*)
    cdef void _fulfill(self, object value)
    cdef void _reject(self, Exception reason, object traceback=*)
    cdef void _reject_callback(self, Exception reason, object traceback=*)
    cdef void _clear_callback_data_index_at(self, int index)
    cdef void _fulfill_promises(self, int length, object value)
    cdef void _reject_promises(self, int length, Exception reason)
    cdef void _settle_promise(self, Promise promise, handler, value, traceback)
    cdef void _settle_promise0(self, handler, value, traceback)
    cdef void _settle_promise_from_handler(self, handler, value, Promise promise)
    cdef void _migrate_callback0(self, Promise follower)
    cdef void _migrate_callback_at(self, Promise follower, int index)
    cdef int _add_callbacks(self, fulfill, reject, Promise promise)
    cpdef Promise _target(self)
    cdef Promise _followee(self)
    cdef void _set_followee(self, Promise promise)
    cdef public void _settle_promises(self)
    cdef void _resolve_from_executor(self, executor)
    cdef void _wait(self, object timeout=*)
    cpdef object get(self, object timeout=*)
    cpdef object _target_settled_value(self, bint raise_=*)
    cpdef bint is_pending(self)
    cpdef bint is_fulfilled(self)
    cpdef bint is_rejected(self)
    cpdef Promise catch(self, on_rejection)
    cdef Promise _then(self, did_fulfill=*, did_reject=*)
    cpdef void do_resolve(self, object value)
    cpdef void do_reject(self, Exception reason, object traceback=*)
    cpdef Promise then(self, object did_fulfill=*, object did_reject=*)
    cpdef void done(self, did_fulfill=*, did_reject=*)
    cpdef void done_all(self, handlers=*)
    cpdef list then_all(self, handlers=*)


cpdef bint is_thenable(object obj)
cpdef Promise try_convert_to_promise(object obj)
