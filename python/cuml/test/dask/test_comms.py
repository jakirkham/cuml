# Copyright (c) 2019, NVIDIA CORPORATION.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

import pytest

import random

import time

from dask.distributed import Client, wait

from cuml.dask.common.comms import CommsContext, worker_state, default_comms
from cuml.dask.common import perform_test_comms_send_recv
from cuml.dask.common import perform_test_comms_allreduce

pytestmark = pytest.mark.mg


def test_comms_init_no_p2p(cluster):

    client = Client(cluster)

    try:
        cb = CommsContext(comms_p2p=False)
        cb.init()

        assert cb.nccl_initialized is True
        assert cb.ucx_initialized is False

    finally:

        cb.destroy()
        client.close()


def test_comms_init_p2p_no_ucx(cluster):

    client = Client(cluster)

    try:
        cb = CommsContext(comms_p2p=True)
        cb.init()

        assert cb.nccl_initialized is True
        assert cb.ucx_initialized is False

    finally:
        cb.destroy()
        client.close()


def func_test_allreduce(sessionId, r):
    handle = worker_state(sessionId)["handle"]
    return perform_test_comms_allreduce(handle)


def func_test_send_recv(sessionId, n_trials, r):
    handle = worker_state(sessionId)["handle"]
    return perform_test_comms_send_recv(handle, n_trials)


@pytest.mark.skip(reason="default_comms() not yet being used")
def test_default_comms_no_exist(cluster):

    client = Client(cluster)

    try:
        cb = default_comms()
        assert cb is not None

        cb2 = default_comms()
        assert cb.sessionId == cb2.sessionId

    finally:
        cb.destroy()
        client.close()


@pytest.mark.skip(reason="default_comms() not yet being used")
def test_default_comms(cluster):

    client = Client(cluster)

    try:
        cb = CommsContext(comms_p2p=True, client=client)
        cb.init()

        comms = default_comms()
        assert(cb.sessionId == comms.sessionId)

    finally:
        comms.destroy()
        client.close()


def test_allreduce(cluster):

    client = Client(cluster)

    try:
        cb = CommsContext()
        cb.init()

        start = time.time()
        dfs = [client.submit(func_test_allreduce, cb.sessionId,
                             random.random(), workers=[w])
               for wid, w in zip(range(len(cb.worker_addresses)),
                                 cb.worker_addresses)]
        wait(dfs)

        print("Time: " + str(time.time() - start))

        print(str(list(map(lambda x: x.result(), dfs))))

        assert all(list(map(lambda x: x.result(), dfs)))

    finally:
        cb.destroy()
        client.close()


@pytest.mark.skip(reason="UCX support not enabled in CI")
def test_send_recv(n_trials, cluster):

    client = Client(cluster)

    try:

        cb = CommsContext(comms_p2p=True)
        cb.init()

        cb = default_comms()

        start = time.time()
        dfs = [client.submit(func_test_send_recv,
                             cb.sessionId,
                             n_trials,
                             random.random(),
                             workers=[w])
               for wid, w in zip(range(len(cb.worker_addresses)),
                                 cb.worker_addresses)]

        wait(dfs)
        print("Time: " + str(time.time() - start))

        result = list(map(lambda x: x.result(), dfs))

        print(str(result))

        assert(result)

    finally:
        cb.destroy()
        client.close()
