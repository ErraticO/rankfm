#!python
#cython: language_level=3, boundscheck=False, wraparound=False, cdivision=True

# -----------------------
# [C/Python] dependencies
# -----------------------

from libc.stdlib cimport malloc, free, rand
from libc.math cimport log, exp, pow
cimport cython

import numpy as np

# --------------------
# [C] helper functions
# --------------------

cdef int lsearch(int item, int *items, int n) nogil:
    """linear search for a given item in a sorted array of items"""

    cdef int i
    for i in range(n):
        if item == items[i]:
            return 1
    return 0


cdef int bsearch(int item, int *items, int n) nogil:
    """binary search for a given item in a sorted array of items"""

    cdef int lo = 0
    cdef int hi = n - 1
    cdef int md

    while lo <= hi:
        md = int(lo + (hi - lo) / 2)
        if items[md] == item:
            return 1
        elif (items[md] < item):
            lo = md + 1
        else:
            hi = md - 1
    return 0


cdef float compute_ui_utility(
    int F,
    int P,
    int Q,
    float *x_uf,
    float *x_if,
    float *w_i,
    float *w_if,
    float *v_u,
    float *v_i,
    float *v_uf,
    float *v_if,
    int x_uf_any,
    int x_if_any
) nogil:

    cdef int f, p, q
    cdef float res = w_i[0]

    for f in range(F):
        # user * item: np.dot(v_u[u], v_i[i])
        res += v_u[f] * v_i[f]

    if x_uf_any:
        for p in range(P):
            if x_uf[p] == 0.0:
                continue
            for f in range(F):
                # user-features * item: np.dot(x_uf[u], np.dot(v_uf, v_i[i]))
                res += x_uf[p] * (v_uf[(F * p) + f] * v_i[f])

    if x_if_any:
        for q in range(Q):
            if x_if[q] == 0.0:
                continue
            # item-features: np.dot(x_if[i], w_if)
            res += x_if[q] * w_if[q]
            for f in range(F):
                # item-features * user: np.dot(x_if[i], np.dot(v_if, v_u[u]))
                res += x_if[q] * (v_if[(F * q) + f] * v_u[f])

    return res

# -------------------------
# [Python] helper functions
# -------------------------

def assert_finite(w_i, w_if, v_u, v_i, v_uf, v_if):
    """assert all model weights are finite"""

    assert np.isfinite(np.sum(w_i)), "item weights [w_i] are not finite - try decreasing feature/sample_weight magnitudes"
    assert np.isfinite(np.sum(w_if)), "item feature weights [w_if] are not finite - try decreasing feature/sample_weight magnitudes"
    assert np.isfinite(np.sum(v_u)), "user factors [v_u] are not finite - try decreasing feature/sample_weight magnitudes"
    assert np.isfinite(np.sum(v_i)), "item factors [v_i] are not finite - try decreasing feature/sample_weight magnitudes"
    assert np.isfinite(np.sum(v_uf)), "user-feature factors [v_uf] are not finite - try decreasing feature/sample_weight magnitudes"
    assert np.isfinite(np.sum(v_if)), "item-feature factors [v_if] are not finite - try decreasing feature/sample_weight magnitudes"


def reg_penalty(regularization, w_i, w_if, v_u, v_i, v_uf, v_if):
    """calculate the total regularization penalty for all model weights"""

    penalty = 0.0
    penalty += np.sum(regularization * np.square(w_i))
    penalty += np.sum(regularization * np.square(w_if))
    penalty += np.sum(regularization * np.square(v_u))
    penalty += np.sum(regularization * np.square(v_i))
    penalty += np.sum(regularization * np.square(v_uf))
    penalty += np.sum(regularization * np.square(v_if))
    return penalty

# --------------------------------
# [RankFM] core modeling functions
# --------------------------------

def fit(
    int[:, ::1] interactions,
    float[:] sample_weight,
    dict user_items,
    float[:, ::1] x_uf,
    float[:, ::1] x_if,
    float[:] w_i,
    float[:] w_if,
    float[:, ::1] v_u,
    float[:, ::1] v_i,
    float[:, ::1] v_uf,
    float[:, ::1] v_if,
    float regularization,
    float learning_rate,
    float learning_exponent,
    int max_samples,
    int epochs,
):

    #############################
    ### VARIABLE DECLARATIONS ###
    #############################

    # matrix shapes/indicators
    cdef int N, U, I, P, Q, F
    cdef int x_uf_any, x_if_any

    # loop iterators/indices
    cdef int f, r, u, i, j
    cdef int epoch, row, sampled

    # epoch-specific learning rate and log-likelihood
    cdef float eta, log_likelihood

    # sample weights and (ui, uj) utility scores
    cdef float sw, ut_ui, ut_uj

    # WARP sampling variables
    cdef int margin = 1
    cdef int min_index
    cdef float pairwise_utility, min_pairwise_utility

    # loss function derivatives wrt model weights
    cdef float d_outer
    cdef float d_reg = 2.0 * regularization
    cdef float d_w_i = 1.0
    cdef float d_w_j = -1.0
    cdef float d_w_if, d_v_i, d_v_j, d_v_u, d_v_uf, d_v_if

    #######################################
    ### PYTHON SET-UP PRIOR TO TRAINING ###
    #######################################

    # calculate matrix shapes
    N = interactions.shape[0]
    U = v_u.shape[0]
    I = v_i.shape[0]
    P = v_uf.shape[0]
    Q = v_if.shape[0]
    F = v_u.shape[1]

    # determine whether any user-features/item-features were supplied
    x_uf_any = int(np.asarray(x_uf).any())
    x_if_any = int(np.asarray(x_if).any())

    # create a shuffle index to diversify each training epoch and register as a memoryview to use in NOGIL
    shuffle_index = np.arange(N, dtype=np.int32)
    cdef int[:] shuffle_index_mv = shuffle_index

    # count the total number of items for each user
    items_user = {user: len(items) for user, items in user_items.items()}

    # create c-arrays: number of items and sorted array of items for each user
    cdef int *c_items_user = <int*>malloc(U * sizeof(int))
    cdef int **c_user_items = <int**>malloc(U * sizeof(int*))

    # fill the c-arrays from the P-arrays to use later in NOGIL blocks
    for u in range(U):
        c_items_user[u] = items_user[u]
        c_user_items[u] = <int*>malloc(c_items_user[u] * sizeof(int))
        for i in range(c_items_user[u]):
            c_user_items[u][i] = user_items[u][i]

    ################################
    ### MAIN TRAINING EPOCH LOOP ###
    ################################

    for epoch in range(epochs):

        np.random.shuffle(shuffle_index)
        eta = learning_rate / pow(epoch + 1, learning_exponent)
        log_likelihood = 0.0

        for r in range(N):

            # locate the observed (user, item, sample-weight)
            row = shuffle_index_mv[r]
            u = interactions[row, 0]
            i = interactions[row, 1]
            sw = sample_weight[row]

            # compute the utility score of the observed (u, i) pair
            ut_ui = compute_ui_utility(
                F,
                P,
                Q,
                &x_uf[u, 0],
                &x_if[i, 0],
                &w_i[i],
                &w_if[0],
                &v_u[u, 0],
                &v_i[i, 0],
                &v_uf[0, 0],
                &v_if[0, 0],
                x_uf_any,
                x_if_any
            )

            # WARP sampling loop for the (u, i) pair
            # --------------------------------------

            min_index = -1
            min_pairwise_utility = 1e6

            for sampled in range(1, max_samples + 1):

                # randomly sample an unobserved item (j) for the user
                while True:
                    j = rand() % I
                    if not lsearch(j, c_user_items[u], c_items_user[u]):
                        break

                # compute the utility score of the unobserved (u, j) pair and the subsequent pairwise utility
                ut_uj = compute_ui_utility(
                    F,
                    P,
                    Q,
                    &x_uf[u, 0],
                    &x_if[j, 0],
                    &w_i[j],
                    &w_if[0],
                    &v_u[u, 0],
                    &v_i[j, 0],
                    &v_uf[0, 0],
                    &v_if[0, 0],
                    x_uf_any,
                    x_if_any
                )
                pairwise_utility = ut_ui - ut_uj

                if pairwise_utility < min_pairwise_utility:
                    min_index = j
                    min_pairwise_utility = pairwise_utility

                if pairwise_utility < margin:
                    break

            # set the final sampled negative item index and calculate the WARP multiplier
            j = min_index
            pairwise_utility = min_pairwise_utility
            multiplier = log((I - 1) / sampled) / log(I)
            log_likelihood += log(1 / (1 + exp(-pairwise_utility)))

            # gradient step model weight updates
            # ----------------------------------

            # calculate the outer derivative [d_LL / d_g(pu)]
            d_outer = 1.0 / (exp(pairwise_utility) + 1.0)

            # update the [item] weights
            w_i[i] += eta * (sw * multiplier * (d_outer * d_w_i) - (d_reg * w_i[i]))
            w_i[j] += eta * (sw * multiplier * (d_outer * d_w_j) - (d_reg * w_i[j]))

            # update the [item-feature] weights
            if x_if_any:
                for q in range(Q):
                    d_w_if = x_if[i, q] - x_if[j, q]
                    w_if[q] += eta * (sw * multiplier * (d_outer * d_w_if) - (d_reg * w_if[q]))

            # update all [factor] weights
            for f in range(F):

                # [user-factor] and [item-factor] derivatives wrt [user-factors] and [item-factors]
                d_v_u = v_i[i, f] - v_i[j, f]
                d_v_i = v_u[u, f]
                d_v_j = -v_u[u, f]

                # add [user-features] to [item-factor] derivatives if supplied
                if x_uf_any:
                    for p in range(P):
                        d_v_i += v_uf[p, f] * x_uf[u, p]
                        d_v_j -= v_uf[p, f] * x_uf[u, p]

                # add [item-features] in [user-factor] derivatives if supplied
                if x_if_any:
                    for q in range(Q):
                        d_v_u += v_if[q, f] * (x_if[i, q] - x_if[j, q])

                # update the [user-factor] and [item-factor] weights with the final gradient values
                v_u[u, f] += eta * (sw * multiplier * (d_outer * d_v_u) - (d_reg * v_u[u, f]))
                v_i[i, f] += eta * (sw * multiplier * (d_outer * d_v_i) - (d_reg * v_i[i, f]))
                v_i[j, f] += eta * (sw * multiplier * (d_outer * d_v_j) - (d_reg * v_i[j, f]))

                # update the [user-feature-factor] weights if user features were supplied
                if x_uf_any:
                    for p in range(P):
                        if x_uf[u, p] == 0.0:
                            continue
                        d_v_uf = x_uf[u, p] * (v_i[i, f] - v_i[j, f])
                        v_uf[p, f] += eta * (sw * multiplier * (d_outer * d_v_uf) - (d_reg * v_uf[p, f]))

                # update the [item-feature-factor] weights if item features were supplied
                if x_if_any:
                    for q in range(Q):
                        if x_if[i, q] - x_if[j, q] == 0:
                            continue
                        d_v_if = (x_if[i, q] - x_if[j, q]) * v_u[u, f]
                        v_if[q, f] += eta * (sw * multiplier * (d_outer * d_v_if) - (d_reg * v_if[q, f]))

        ##########################
        ### END TRAINING EPOCH ###
        ##########################

        # assert all model weights are finite as of the end of this epoch
        assert_finite(w_i, w_if, v_u, v_i, v_uf, v_if)

        # report the penalized log-likelihood for this training epoch
        penalty = reg_penalty(regularization, w_i, w_if, v_u, v_i, v_uf, v_if)
        log_likelihood = round(log_likelihood - penalty, 2)
        print("\ntraining epoch:", epoch)
        print("log likelihood:", log_likelihood)

    ####################################
    ### END MAIN TRAINING EPOCH LOOP ###
    ####################################

    # free c-arrays memory
    for u in range(U):
        free(c_user_items[u])
    free(c_items_user)
    free(c_user_items)

