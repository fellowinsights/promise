cimport cython

from asyncio import Future, ensure_future
from functools import wraps
from inspect import iscoroutine
from sys import exc_info

from .async_ cimport Async
from .promise_list cimport PromiseList
from .schedulers cimport Scheduler, SchedulerFn
from .schedulers.immediate cimport ImmediateScheduler


cdef int MAX_LENGTH = 0xFFFF | 0
DEFAULT_TIMEOUT = None

cdef Async async_instance = Async()
cdef Scheduler default_scheduler = ImmediateScheduler()


cdef class Box:
    cdef public object value


def get_async_instance():
    return async_instance


def get_default_scheduler():
    return default_scheduler


def set_default_scheduler(scheduler):
    global default_scheduler
    default_scheduler = scheduler


@cython.final
cdef class TryCatchResult:
    cdef:
        object value, tb
        Exception exc


cdef TryCatchResult try_catch(object handler, object value):
    cdef:
        TryCatchResult res = TryCatchResult.__new__(TryCatchResult)
        Exception e
    try:
        res.value = handler(value)
        res.exc = None
        res.tb = None
    except Exception as e:
        res.value = None
        res.tb = exc_info()[2]
        res.exc = e
    return res


@cython.final
cdef class PartialSettlePromise(SchedulerFn):
    cdef public:
        Promise target, promise
        object handler, value, traceback

    cdef void call(self) except *:
        self.target._settle_promise(
            self.promise,
            self.handler,
            self.value,
            self.traceback,
        )


@cython.final
cdef class Promise:
    def __init__(self, executor=None, scheduler=None):
        self._state = State.PENDING
        self._length = 0
        self._is_final = \
            self._is_bound = \
            self._is_following = \
            self._is_async_guaranteed = \
            self._is_waiting = False
        self._fulfillment_handler0 = \
            self._rejection_handler0 = \
            self._promise0 = \
            self._future = \
            self._traceback = None
        self._scheduler = scheduler
        self._promises = []
        self._rejection_handlers = []
        self._fulfillment_handlers = []

        if executor is not None:
            self._resolve_from_executor(executor)

    cpdef Scheduler get_scheduler(self):
        if self._scheduler is not None:
            return self._scheduler
        return default_scheduler

    cpdef object get_future(self):
        cdef object fut
        if not self._future:
            fut = self._future = Future()
            self._then(fut.set_result, fut.set_exception)
        return self._future

    def __iter__(self):
        return iterate_promise(self._target())

    def __await__(self):
        return self.__iter__()

    cdef void _resolve_callback(self, object value):
        cdef int len, i

        if value is self:
            self._reject_callback(TypeError("Promise is self"))
            return
        if not _is_thenable(value):
            self._fulfill(value)
            return

        cdef Promise promise = _try_convert_to_promise(value)._target()
        if promise is self:
            self._reject(TypeError("Promise is self"))
            return

        if promise._state == State.PENDING:
            len = self._length
            if len > 0:
                promise._migrate_callback0(self)
            for i in range(1, len):
                promise._migrate_callback_at(self, i)
            self._is_following = True
            self._length = 0
            self._set_followee(promise)
        elif promise._state == State.FULFILLED:
            self._fulfill(promise._target_settled_value())
        elif promise._state == State.REJECTED:
            self._reject(
                promise._target_settled_value(), promise._target()._traceback
            )

    cdef object _settled_value(self, bint raise_ = False):
        assert not self._is_following
        if self._state == State.FULFILLED:
            return self._rejection_handler0
        elif self._state == State.REJECTED:
            if raise_:
                raise_val = self._fulfillment_handler0
                raise raise_val.with_traceback(self._traceback)
            return self._fulfillment_handler0
        return None

    cdef void _fulfill(self, object value):
        if value is self:
            self._reject(TypeError("Promise is self"))
            return
        self._state = State.FULFILLED
        self._rejection_handler0 = value

        if self._length > 0:
            if self._is_async_guaranteed:
                self._settle_promises()
            else:
                async_instance.settle_promises(self)

    cdef void _reject(self, Exception reason, object traceback = None):
        self._state = State.REJECTED
        self._fulfillment_handler0 = reason
        self._traceback = traceback

        if self._is_final:
            assert self._length == 0
            async_instance.fatal_error(reason, self.get_scheduler())
            return

        if self._length > 0:
            async_instance.settle_promises(self)

        if self._is_async_guaranteed:
            self._settle_promises()
        else:
            async_instance.settle_promises(self)

    cdef void _reject_callback(
            self,
            Exception reason,
            object traceback = None
    ):
        self._reject(reason, traceback)

    cdef void _clear_callback_data_index_at(self, int index):
        assert not self._is_following
        assert index >= 0
        self._promises[index] = None
        self._rejection_handlers[index] = None
        self._fulfillment_handlers[index] = None

    cdef void _fulfill_promises(self, int length, object value):
        cdef Promise promise
        cdef int i

        for i in range(length - 1):
            handler = self._fulfillment_handlers[i]
            promise = self._promises[i]
            self._clear_callback_data_index_at(i)
            self._settle_promise(promise, handler, value, None)

    cdef void _reject_promises(self, int length, Exception reason):
        cdef Promise promise
        cdef int i

        for i in range(length - 1):
            handler = self._rejection_handlers[i]
            promise = self._promises[i]
            self._clear_callback_data_index_at(i)
            self._settle_promise(promise, handler, reason, None)

    cdef void _settle_promise(self, Promise promise, handler, value, traceback):
        assert not self._is_following
        cdef bint is_promise = isinstance(promise, Promise), \
            async_guaranteed = self._is_async_guaranteed

        if callable(handler):
            if not is_promise:
                handler(value)
            else:
                if async_guaranteed:
                    promise._is_async_guaranteed = True
                self._settle_promise_from_handler(
                    handler, value, promise,
                )
        elif is_promise:
            if async_guaranteed:
                promise._is_async_guaranteed = True
            if self._state == State.FULFILLED:
                promise._fulfill(value)
            else:
                promise._reject(value, self._traceback)

    cdef void _settle_promise0(self, handler, value, traceback):
        cdef Promise promise = self._promise0
        self._promise0 = None
        self._settle_promise(promise, handler, value, traceback)

    cdef void _settle_promise_from_handler(self, handler, value, Promise promise):
        cdef TryCatchResult result = try_catch(handler, value)

        if result.exc is not None:
            promise._reject_callback(result.exc, result.tb)
        else:
            promise._resolve_callback(result.value)

    cdef void _migrate_callback0(self, Promise follower):
        self._add_callbacks(
            follower._fulfillment_handler0,
            follower._rejection_handler0,
            follower._promise0,
        )

    cdef void _migrate_callback_at(self, Promise follower, int index):
        self._add_callbacks(
            follower._fulfillment_handlers[index],
            follower._rejection_handlers[index],
            follower._promises[index],
        )

    cdef int _add_callbacks(self, fulfill, reject, Promise promise):
        assert not self._is_following
        cdef int index = self._length % MAX_LENGTH, \
                idx = index - 1
        self._length = index

        if index == 0:
            assert not self._promise0
            assert not self._fulfillment_handler0
            assert not self._rejection_handler0

            self._promise0 = promise
            if callable(fulfill):
                self._fulfillment_handler0 = fulfill
            if callable(reject):
                self._rejection_handler0 = reject
        else:
            if idx >= len(self._promises):
                self._promises.append(None)
                self._fulfillment_handlers.append(None)
                self._rejection_handlers.append(None)
            else:
                assert self._promises[idx] is None
                assert self._fulfillment_handlers[idx] is None
                assert self._rejection_handlers[idx] is None

            self._promises[idx] = promise
            if callable(fulfill):
                self._fulfillment_handlers[idx] = fulfill
            if callable(reject):
                self._rejection_handlers[idx] = reject

        self._length = index + 1
        return index

    cpdef Promise _target(self):
        cdef Promise ret = self
        while ret._is_following:
            ret = ret._followee()
        return ret

    cdef Promise _followee(self):
        assert self._is_following
        assert isinstance(self._rejection_handler0, Promise)
        return self._rejection_handler0

    cdef void _set_followee(self, Promise promise):
        assert self._is_following
        assert not isinstance(self._rejection_handler0, Promise)
        self._rejection_handler0 = promise

    cdef public void _settle_promises(self):
        cdef:
            int length = self._length
            object value, reason
        if length > 0:
            if self._state == State.REJECTED:
                reason = self._fulfillment_handler0
                traceback = self._traceback
                self._settle_promise0(self._rejection_handler0, reason, traceback)
                self._reject_promises(length, reason)
            else:
                value = self._rejection_handler0
                self._settle_promise0(self._fulfillment_handler0, value, None)
                self._fulfill_promises(length, value)

            self._length = 0

    cdef void _resolve_from_executor(self, executor):
        def resolve(value):
            self._resolve_callback(value)

        def reject(reason, traceback=None):
            self._reject_callback(reason, traceback)

        error = traceback = None
        try:
            executor(resolve, reject)
        except Exception as e:
            traceback = exc_info()[2]
            error = e

        if error is not None:
            self._reject_callback(error, traceback)

    @staticmethod
    def wait(Promise promise, object timeout = None):
        promise._wait(timeout)

    cpdef void _wait(self, object timeout = None):
        async_instance.wait(self, timeout)

    cpdef object get(self, object timeout = None):
        self._wait(timeout or DEFAULT_TIMEOUT)
        return self._target_settled_value(raise_=True)

    cdef object _target_settled_value(self, bint raise_ = False):
        return self._target()._settled_value(raise_)

    @property
    def value(self):
        return self._target_settled_value()

    @property
    def reason(self):
        return self._target_settled_value()

    def __repr__(self):
        hex_id = hex(id(self))
        if self._is_following:
            return "<Promise at {} following {}>".format(hex_id, self._target())
        state = self._state
        if state == State.PENDING:
            return "<Promise at {} pending>".format(hex_id)
        elif state == State.FULFILLED:
            return "<Promise at {} fulfilled with {}>".format(
                hex_id, repr(self._rejection_handler0)
            )
        elif state == State.REJECTED:
            return "<Promise at {} rejected with {}>".format(
                hex_id, repr(self._fulfillment_handler0)
            )

        return "<Promise unknown>"

    cdef bint _is_pending(self):
        return self._target()._state == State.PENDING

    cdef bint _is_fulfilled(self):
        return self._target()._state == State.FULFILLED

    cdef bint _is_rejected(self):
        return self._target()._state == State.REJECTED

    @property
    def is_pending(self):
        return self._is_pending()

    @property
    def is_fulfilled(self):
        return self._is_fulfilled()

    @property
    def is_rejected(self):
        return self._is_rejected()

    cpdef Promise catch(self, on_rejection):
        return self.then(None, on_rejection)

    cdef Promise _then(self, did_fulfill=None, did_reject=None):
        cdef:
            Promise promise = Promise(), \
                target = self._target()
            State state = target._state
            PartialSettlePromise fn

        if state == State.PENDING:
            target._add_callbacks(did_fulfill, did_reject, promise)
        else:
            traceback = None
            if state == State.FULFILLED:
                value = target._rejection_handler0
                handler = did_fulfill
            elif state == State.REJECTED:
                value = target._fulfillment_handler0
                handler = did_reject

            fn = PartialSettlePromise()
            fn.target = target
            fn.promise = promise
            fn.handler = handler
            fn.value = value
            fn.traceback = traceback
            async_instance.invoke(fn, promise.get_scheduler())

        return promise

    cpdef void do_resolve(self, object value):
        self._resolve_callback(value)

    fulfill = do_resolve

    cpdef void do_reject(self, Exception reason, object traceback = None):
        self._reject_callback(reason, traceback)

    cpdef Promise then(self, object did_fulfill = None, object did_reject = None):
        return self._then(did_fulfill, did_reject)

    cpdef void done(self, did_fulfill=None, did_reject=None):
        cdef Promise promise = self._then(did_fulfill, did_reject)
        promise._is_final = True

    cpdef void done_all(self, handlers=None):
        cdef int i
        cdef list handler_list

        if handlers is None:
            return

        handler_list = list(handlers)
        for i in range(len(handler_list)):
            handler = handler_list[i]
            if isinstance(handler, tuple):
                s, f = handler
                self.done(s, f)
            elif isinstance(handler, dict):
                s = handler.get("success")
                f = handler.get("failure")

                self.done(s, f)
            else:
                self.done(handler)

    cpdef list then_all(self, handlers=None):
        cdef int i

        if handlers is None:
            return []

        cdef list handler_list = list(handlers), \
            promises = []

        for i in range(len(handler_list)):
            handler = handler_list[i]
            if isinstance(handler, tuple):
                s, f = handler
                promises.append(self.then(s, f))
            elif isinstance(handler, dict):
                s = handler.get("success")
                f = handler.get("failure")
                promises.append(self.then(s, f))
            else:
                promises.append(self.then(handler))

        return promises

    @staticmethod
    cdef Promise c_reject(Exception reason):
        ret = Promise()
        ret._reject_callback(reason)
        return ret

    @staticmethod
    def reject(obj: Exception) -> Promise:
        return Promise.c_reject(obj)

    rejected = reject

    @staticmethod
    cdef Promise c_resolve(object obj):
        if not _is_thenable(obj):
            ret = Promise()
            ret._state = State.FULFILLED
            ret._rejection_handler0 = obj
            return ret
        return _try_convert_to_promise(obj)

    @staticmethod
    def resolve(obj) -> Promise:
        return Promise.c_resolve(obj)

    fulfilled = cast = resolve

    @staticmethod
    def promisify(f):
        @wraps(f)
        def wrapper(*args, **kwargs):
            def executor(resolve, reject):
                return resolve(f(*args, **kwargs))

            return Promise(executor)

        return wrapper

    _safe_resolved_promise = Box.__new__(Box)

    @staticmethod
    def safe(fn):
        if not Promise._safe_resolved_promise.value:
            Promise._safe_resolved_promise.value = Promise.resolve(None)

        @wraps(fn)
        def wrapper(*args, **kwargs):
            return Promise._safe_resolved_promise.value.then(lambda v: fn(*args, **kwargs))

        return wrapper

    @staticmethod
    def all(promises) -> Promise:
        return PromiseList(promises).promise

    @staticmethod
    def for_dict(m):
        dict_type = type(m)

        if not m:
            return Promise.resolve(dict_type())

        def handle_success(resolved_values):
            return dict_type(zip(m.keys(), resolved_values))

        return Promise.all(m.values()).then(handle_success)


cdef bint _is_thenable(object obj):
    cdef object typ = type(obj)
    if isinstance(obj, Promise):
        return True
    elif typ in (int, str, bool, float, complex, tuple, list, dict, bytes):
        return False
    elif iscoroutine(obj) or is_future_like(typ):
        return True
    else:
        return False


def is_thenable(obj):
    return _is_thenable(obj)


cdef Promise _try_convert_to_promise(object obj):
    # can't subclass promise, don't need to check
    if isinstance(obj, Promise):
        return obj

    type_ = type(obj)
    if iscoroutine(obj):
        obj = ensure_future(obj)
        type_ = obj.__class__

    if is_future_like(type_):
        def executor(resolve, reject):
            if obj.done():
                _process_future_result(resolve, reject)(obj)
            else:
                obj.add_done_callback(_process_future_result(resolve, reject))

        promise = Promise(executor)
        promise._future = obj
        return promise

    return obj


cdef bint is_future_like(object type_):
    return hasattr(type_, "add_done_callback") and callable(type_.add_done_callback)


promisify = Promise.promisify
promise_for_dict = Promise.for_dict


def _process_future_result(resolve, reject):
    def handle_future_result(future):
        try:
            resolve(future.result())
        except Exception as e:
            tb = exc_info()[2]
            reject(e, tb)

    return handle_future_result


def iterate_promise(promise: Promise) -> object:
    if not promise.is_fulfilled:
        yield from promise.get_future()
    assert promise.is_fulfilled
    return promise.get()
