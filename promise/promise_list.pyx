cimport cython

from .promise cimport Promise, _is_thenable, _try_convert_to_promise


@cython.final
cdef class PartialFulfilled:
    cdef:
        PromiseList promise_list
        int i

    def __call__(self, object value):
        return self.promise_list._promise_fulfilled(value, self.i)


@cython.final
cdef class PartialRejected:
    cdef:
        PromiseList promise_list
        Promise promise

    def __call__(self, Exception reason):
        return self.promise_list._promise_rejected(reason, self.promise)


@cython.final
cdef class PromiseList:
    def __init__(self, values):
        self.promise = Promise()
        self._length = self._total_resolved = 0
        self._values = None

        if _is_thenable(values):
            self._init_promise(_try_convert_to_promise(values)._target())
        else:
            self._init(values)

    cdef void _init_promise(self, Promise values) except *:
        if values.is_fulfilled():
            values = values._target_settled_value()
        elif values.is_rejected():
            self._reject(values._target_settled_value())
            return

        self.promise._is_async_guaranteed = True
        values._then(self._init, self._reject)

    cpdef void _init(self, object values) except *:
        cdef list values_list

        try:
            values_list = list(values)
        except Exception:
            err = Exception(
                "PromiseList requires an iterable. Received {}.".format(repr(values))
            )
            self.promise._reject_callback(err)
            return

        # Assign list to self.values before resolving, otherwise we will get an
        # AssertionError
        self._values = values_list
        if len(values_list) == 0:
            self._resolve(values_list)
            return
        self._iterate(values_list)

    cdef void _iterate(self, list values):
        cdef:
            int i
            bint is_resolved = False
            Promise result = self.promise, \
                maybe_promise
            object val
            PartialFulfilled on_fulfill
            PartialRejected on_reject

        self._length = len(values)
        self._values = [None] * self._length

        for i in range(self._length):
            val = values[i]
            if _is_thenable(val):
                maybe_promise = _try_convert_to_promise(val)._target()
                if maybe_promise.is_pending():
                    on_fulfill = PartialFulfilled.__new__(PartialFulfilled)
                    on_reject = PartialRejected.__new__(PartialRejected)
                    on_fulfill.promise_list = on_reject.promise_list = self
                    on_fulfill.i = i
                    on_reject.promise = maybe_promise
                    maybe_promise._add_callbacks(on_fulfill, on_reject, None)
                    self._values[i] = maybe_promise
                elif maybe_promise.is_fulfilled():
                    is_resolved = self._promise_fulfilled(
                        maybe_promise._target_settled_value(), i
                    )
                elif maybe_promise.is_rejected():
                    is_resolved = self._promise_rejected(
                        maybe_promise._target_settled_value(),
                        promise=maybe_promise,
                    )
            else:
                is_resolved = self._promise_fulfilled(val, i)

            if is_resolved:
                break

        if not is_resolved:
            result._is_async_guaranteed = True

    cdef bint _promise_fulfilled(self, object value, int i):
        if self.is_resolved():
            return False
        self._values[i] = value
        self._total_resolved += 1
        if self._total_resolved >= self._length:
            self._resolve(self._values)
            return True
        return False

    cdef bint _promise_rejected(self, Exception reason, Promise promise):
        if self.is_resolved():
            return False
        self._total_resolved += 1
        self._reject(reason, traceback=promise._target()._traceback)
        return True

    cdef bint is_resolved(self):
        return self._values is None

    cdef void _resolve(self, list value):
        assert not self.is_resolved()
        self._values = None
        self.promise._fulfill(value)

    cpdef void _reject(self, Exception reason, object traceback = None):
        assert not self.is_resolved()
        self._values = None
        self.promise._reject_callback(reason, traceback=traceback)
