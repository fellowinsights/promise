cimport cython

from threading import local

from .schedulers cimport Scheduler, SchedulerFn
from .promise cimport Promise, default_scheduler, async_instance


cdef list get_chunks(object iterable_obj, int chunk_size=1):
    cdef:
        int i
        list chunks = []

    chunk_size = max(1, chunk_size)

    # using old school syntax since Cython wasn't optimizing `range` in this case
    for i from 0 <= i < len(iterable_obj) by chunk_size:
        chunks.append(iterable_obj[i : i + chunk_size])

    return chunks


@cython.final
cdef class DoResolveReject:
    cdef:
        DataLoader loader
        object key

    def __call__(self, object resolve, object reject):
        self.loader.do_resolve_reject(self.key, resolve, reject)


@cython.final
cdef class Loader:
    cdef object key, resolve, reject


@cython.final
cdef class LocalData:
    pass


@cython.final
cdef class DispatchQueueFn(SchedulerFn):
    cdef DataLoader loader

    cdef void call(self):
        dispatch_queue(self.loader)


cdef class DataLoader:
    def __init__(
        self,
        bint batch = True,
        int max_batch_size = -1,
        bint cache = True,
        Scheduler scheduler = None,
    ):
        self.threadlocal = local()
        self.batch = batch
        self.max_batch_size = max_batch_size
        self.cache = cache
        self._scheduler = scheduler

    cdef LocalData local_data(self):
        cdef LocalData loc
        if hasattr(self.threadlocal, "data"):
            loc = self.threadlocal.data
        else:
            loc = LocalData.__new__(LocalData)
            loc.promise_cache = {}
            loc.queue = []
            self.threadlocal.data = loc
        return loc

    cpdef object get_cache_key(self, object o):
        return o

    cpdef Promise batch_load_fn(self, list keys):
        return Promise.c_resolve([None for _ in keys])

    def load(self, key) -> Promise:
        return self._load(key)

    cdef Promise _load(self, object key):
        if key is None:
            raise TypeError(
                "The loader.load() function must be called with a value, "
                "but got None."
            )

        cdef:
            LocalData loc = self.local_data()
            object cache_key = self.get_cache_key(key)
            Promise cached_promise

        if self.cache:
            cached_promise = loc.promise_cache.get(cache_key)
            if cached_promise is not None:
                return cached_promise

        cdef:
            DoResolveReject executor = DoResolveReject.__new__(DoResolveReject)
            Promise promise

        executor.loader = self
        executor.key = key
        promise = Promise(executor)

        if self.cache:
            loc.promise_cache[cache_key] = promise

        return promise

    cdef void do_resolve_reject(self, key, resolve, reject):
        cdef:
            LocalData loc = self.local_data()
            Loader loader = Loader.__new__(Loader)
            DispatchQueueFn fn_dispatch_queue

        loader.key = key
        loader.resolve = resolve
        loader.reject = reject
        # Enqueue this Promise to be dispatched
        loc.queue.append(loader)

        # Determine if a dispatch of this queue should be scheduled.
        # A single dispatch should be scheduled per queue at the time when the
        # queue changes from "empty" to "full".
        if len(loc.queue) == 1:
            if self.batch:
                fn_dispatch_queue = DispatchQueueFn.__new__(DispatchQueueFn)
                fn_dispatch_queue.loader = self
                # If batching, schedule a task to dispatch the queue.
                enqueue_post_promise_job(fn_dispatch_queue, self._scheduler)
            else:
                # Otherwise dispatch the (queue of one) immediately.
                dispatch_queue(self)

    cpdef Promise load_many(self, object keys):
        cdef list key_list

        try:
            key_list = list(keys)
        except Exception as e:
            raise TypeError(
                "The loader.load_many() function must be called with an "
                "iterable of keys."
            ) from e

        return Promise.all([self.load(key) for key in key_list])

    cpdef DataLoader clear(self, object key):
        cdef:
            LocalData loc = self.local_data()
            object cache_key = self.get_cache_key(key)
        del loc.promise_cache[cache_key]
        return self

    cpdef DataLoader clear_all(self):
        cdef LocalData loc = self.local_data()
        loc.promise_cache.clear()
        return self

    cpdef DataLoader prime(self, key, value):
        cdef:
            LocalData loc = self.local_data()
            object cache_key = self.get_cache_key(key)
            Exception exc
            Promise promise

        if cache_key not in loc.promise_cache:
            if isinstance(value, Exception):
                exc = value
                promise = Promise.c_reject(exc)
            else:
                promise = Promise.c_resolve(value)
            self._promise_cache[cache_key] = promise

        return self


@cython.final
cdef class OnPromiseResolve:
    cdef public:
        Scheduler scheduler
        SchedulerFn fn

    def __call__(self, _value):
        async_instance.invoke(self.fn, self.scheduler)


cdef object cache = local()


cdef void enqueue_post_promise_job(DispatchQueueFn fn, Scheduler scheduler):
    cdef:
        Promise resolved_promise
        OnPromiseResolve then = OnPromiseResolve.__new__(OnPromiseResolve)

    global cache
    if hasattr(cache, "resolved_promise"):
        resolved_promise = cache.resolved_promise
    else:
        resolved_promise = cache.resolved_promise = Promise.c_resolve(None)
    if scheduler is None:
        scheduler = default_scheduler

    then.fn = fn
    then.scheduler = scheduler
    resolved_promise.then(then)


cdef void dispatch_queue(DataLoader loader):
    cdef:
        LocalData loc = loader.local_data()
        list queue = loc.queue
        int max_batch_size = loader.max_batch_size
        list chunks, chunk

    loc.queue = []

    if max_batch_size is not None and max_batch_size > len(queue):
        chunks = get_chunks(queue, max_batch_size)
        for chunk in chunks:
            dispatch_queue_batch(loader, chunk)
    else:
        dispatch_queue_batch(loader, queue)


@cython.final
cdef class BatchPromiseResolved:
    cdef public list keys, queue

    def __call__(self, object values):
        cdef list value_list

        try:
            value_list = list(values)
        except Exception:
            raise TypeError("Expected promise of list")

        if len(value_list) != len(self.keys):
            raise TypeError("Expected length of result to match length of keys")

        cdef:
            int i
            Loader loader
            object value

        for i in range(len(value_list)):
            loader = self.queue[i]
            value = value_list[i]
            if isinstance(value, Exception):
                loader.reject(value)
            else:
                loader.resolve(value)


@cython.final
cdef class FailedDispatch:
    cdef public:
        DataLoader loader
        list queue

    def __call__(self, error):
        failed_dispatch(self.loader, self.queue, error)


cdef void dispatch_queue_batch(DataLoader loader, list queue):
    cdef:
        list keys = []
        int i
        Loader l
        Promise batch_promise

    for i in range(len(queue)):
        l = queue[i]
        keys.append(l.key)

    try:
        batch_promise = loader.batch_load_fn(keys)
    except Exception as e:
        failed_dispatch(loader, queue, e)
        return

    if batch_promise is None or not isinstance(batch_promise, Promise):
        failed_dispatch(
            loader,
            queue,
            TypeError(
                "Expected a promise of list, got: {}".format(batch_promise)
            ),
        )
        return

    cdef:
        BatchPromiseResolved then
        FailedDispatch catch
    then = BatchPromiseResolved.__new__(BatchPromiseResolved)
    then.keys = keys
    then.queue = queue
    catch = FailedDispatch.__new__(FailedDispatch)
    catch.loader = loader
    catch.queue = queue

    batch_promise.then(then).catch(catch)


cdef void failed_dispatch(DataLoader loader, list queue, Exception error):
    cdef Loader l
    for l in queue:
        loader.clear(l.key)
        l.reject(error)
