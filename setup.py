import sys, os
from setuptools import setup, find_packages
from distutils.core import Extension

try:
    import Cython
except ImportError:
    USE_CYTHON = False
else:
    USE_CYTHON = True

pyx = "pyx" if USE_CYTHON else "c"
py = "py" if USE_CYTHON else "c"

ext_modules = [
    Extension("promise", [f"promise/__init__.{py}"]),
    Extension("promise.promise", [f"promise/promise.{pyx}"]),
    Extension("promise.promise_list", [f"promise/promise_list.{pyx}"]),
    Extension("promise.dataloader", [f"promise/dataloader.{pyx}"]),
    Extension("promise.async_", [f"promise/async_.{pyx}"]),
    Extension("promise.schedulers", [f"promise/schedulers/__init__.{py}"]),
    Extension("promise.schedulers.base", [f"promise/schedulers/base.{pyx}"]),
    Extension("promise.schedulers.immediate", [f"promise/schedulers/immediate.{pyx}"]),
    Extension("promise.pyutils", [f"promise/pyutils/__init__.{py}"]),
    Extension("promise.pyutils.version", [f"promise/pyutils/version.{py}"]),
]

if USE_CYTHON:
    from Cython.Build import cythonize

    do_profile = bool(os.getenv("PROFILE"))
    ext_modules = cythonize(
        ext_modules,
        compiler_directives={
            "language_level": "3",
            "warn.unused": True,
            "warn.unused_result": True,
            "linetrace": do_profile,
            "profile": do_profile,
        },
    )

import builtins

builtins.__SETUP__ = True  # type: ignore

version = __import__("promise").get_version()


tests_require = [
    "pytest>=2.7.3",
    "pytest-cov",
    "coveralls",
    "pytest-benchmark",
    "mock",
    "pytest-asyncio",
]


setup(
    name="promise",
    version=version,
    description="Promises/A+ implementation for Python",
    long_description=open("README.rst").read(),
    url="https://github.com/syrusakbary/promise",
    download_url="https://github.com/syrusakbary/promise/releases",
    author="Syrus Akbary",
    author_email="me@syrusakbary.com",
    license="MIT",
    classifiers=[
        "Development Status :: 5 - Production/Stable",
        "Intended Audience :: Developers",
        "Topic :: Software Development :: Libraries",
        "Programming Language :: Python :: 3.6",
        "Programming Language :: Python :: 3.7",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: Implementation :: CPython",
        "License :: OSI Approved :: MIT License",
    ],
    keywords="concurrent future deferred promise",
    packages=find_packages(exclude=["tests"]),
    # PEP-561: https://www.python.org/dev/peps/pep-0561/
    package_data={"promise": ["py.typed"]},
    extras_require={"test": tests_require},
    install_requires=["typing>=3.6.4; python_version < '3.5'"],
    tests_require=tests_require,
    ext_modules=ext_modules,
)
