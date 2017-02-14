from promise import Promise
from promise.dataloader import DataLoader


def id_loader(**options):
    load_calls = []
    
    def fn(keys):
        load_calls.append(keys)
        return Promise.resolve(keys)
    
    identity_loader = DataLoader(fn, **options)
    return identity_loader, load_calls


def test_build_a_simple_data_loader():
    def call_fn(keys):
        return Promise.resolve(keys)
    identity_loader = DataLoader(call_fn)

    promise1 = identity_loader.load(1)
    assert isinstance(promise1, Promise)

    value1 = promise1.get()
    assert value1 == 1


def test_supports_loading_multiple_keys_in_one_call():
    def call_fn(keys):
        return Promise.resolve(keys)
    identity_loader = DataLoader(call_fn)

    promise_all = identity_loader.load_many([1, 2])
    assert isinstance(promise_all, Promise)

    values = promise_all.get()
    assert values == [1, 2]

    promise_all = identity_loader.load_many([])
    assert isinstance(promise_all, Promise)

    values = promise_all.get()
    assert values == []


def test_batches_multiple_requests():
    identity_loader, load_calls = id_loader()


    promise1 = identity_loader.load(1)
    promise2 = identity_loader.load(2)

    value1, value2 = Promise.all([promise1, promise2]).get()
    assert value1 == 1
    assert value2 == 2

    assert load_calls == [[1, 2]]
