// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Error-handling helpers used at the seam between ASI's legacy bool /
// pointer return idioms and nros-cpp's `nros::Result`. Pulled in only
// by the Phase 1C nano-ros shim (`common/node/node_nros.hpp`); does
// not affect the legacy raw-Cyclone path.

#ifndef COMMON__NODE__NROS_ERROR_HPP_
#define COMMON__NODE__NROS_ERROR_HPP_

#include <nros/nros.hpp>

#include "common/logger/logger.hpp"

namespace asi {
namespace nros_shim {

// Coerce a nros::Result into a bool while logging the raw error code
// through ASI's existing logger. Returns true on ok().
inline bool check(const char * what, ::nros::Result r)
{
    if (r.ok()) {
        return true;
    }
    common::logger::log_error("%s -> nros err %d\n", what, r.raw());
    return false;
}

}  // namespace nros_shim
}  // namespace asi

// Early-return-bool-false on nros::Result error. Same shape as
// NROS_TRY_RET but tailored to ASI's bool-returning shim methods.
#define ASI_NROS_OR_FALSE(expr)                                        \
    do {                                                               \
        auto _r = (expr);                                              \
        if (!_r.ok()) {                                                \
            common::logger::log_error(#expr " -> %d\n", _r.raw());     \
            return false;                                              \
        }                                                              \
    } while (0)

#endif  // COMMON__NODE__NROS_ERROR_HPP_
