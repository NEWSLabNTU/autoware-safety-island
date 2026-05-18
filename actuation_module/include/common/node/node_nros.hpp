// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Phase 1C — `Node` shim sitting on top of nros-cpp. Parallels the
// legacy raw-Cyclone Node at `common/node/node.hpp`. The two coexist
// during migration; CMake's `ASI_USE_NANO_ROS` option picks which one
// `common/node/node.hpp` re-exports (router pattern lands in a follow-
// up commit alongside the call-site descriptor-arg cleanup).
//
// Design notes (full report under
// /home/aeon/.claude/projects/.../memory and docs/roadmap/phase-1C-node-adapter.md):
//
//   - Lifecycle: `nros::init` / `nros::shutdown` are called from
//     ASI's existing `main.cpp` (preserved to keep the DHCP+SNTP
//     prologue intact). This file does NOT call them.
//
//   - Parameter storage: stays Node-local in a `std::unordered_map<
//     std::string, param_type>` (variant identical to the legacy
//     header). nros::ParameterServer v1 only supports scalar types
//     (bool/i64/f64/string); ASI's MPC controller declares
//     `std::vector<double>` weights matrices that don't fit.
//     Keeping the local map sidesteps that blocker; an upstream nros
//     vector-param patch is a separate follow-up.
//
//   - Subscriptions: nros-cpp uses manual `try_recv<M>` polling, same
//     model as ASI's current `dds_.execute_subscriptions()`. Each
//     subscription wraps a typed trampoline that closes over the
//     legacy `void(*)(const T*, void*)` callback + `void* arg` shape.
//
//   - Descriptor arg: the legacy `create_publisher` /
//     `create_subscription` carry a `dds_topic_descriptor_t*`. This
//     shim drops it from its surface. Controller call sites must be
//     updated when ASI_USE_NANO_ROS=ON is exercised (Phase 1.7).
//
//   - QoS: nros-cpp default = keep-last(10). ASI's current Cyclone
//     path uses a deeper history; the QoS override knob is a Phase
//     1C follow-up once the MPC spike reports actual depth needs.

#ifndef COMMON__NODE__NODE_NROS_HPP_
#define COMMON__NODE__NODE_NROS_HPP_

#include <cstddef>
#include <cstring>
#include <functional>
#include <memory>
#include <optional>
#include <pthread.h>
#include <string>
#include <unordered_map>
#include <variant>
#include <vector>

#include <nros/nros.hpp>

#include "common/node/nros_error.hpp"
#include "common/node/timer.hpp"
#include "common/logger/logger.hpp"
using namespace common::logger;

// Same variant as legacy `common/node/node.hpp`. Keeping the local
// map means controller code that does
//   declare_parameter<std::vector<double>>("mpc.weight_q", default_q)
// works without changes — nros::ParameterServer doesn't accept
// vectors yet.
using param_type = std::variant<bool,
                                int,
                                int64_t,
                                double,
                                std::string,
                                std::vector<bool>,
                                std::vector<int>,
                                std::vector<int64_t>,
                                std::vector<double>,
                                std::vector<std::string>,
                                std::vector<uint8_t>>;

// Callback signature mirrors common/dds/subscriber.hpp:
//   void cb(const T * msg, void * user_arg);
template <typename T>
using callback_subscriber = void (*)(const T *, void *);

namespace asi {
namespace nros_shim {

// Wrapper that preserves the legacy `Publisher<T>::publish(msg) -> bool`
// return shape (true on ok). Holds a shared_ptr to the underlying nros
// entity so the Node + the user-facing handle keep it alive together.
template <typename M>
class Publisher {
public:
    explicit Publisher(std::shared_ptr<::nros::Publisher<M>> inner)
    : inner_(std::move(inner)) {}

    bool publish(const M & msg)
    {
        auto r = inner_->publish(msg);
        if (!r.ok()) {
            log_warn_throttle("nros publish failed: %d", r.raw());
            return false;
        }
        return true;
    }

private:
    std::shared_ptr<::nros::Publisher<M>> inner_;
};

// Type-erased subscription handle so Node can hold a heterogeneous
// vector of typed subscriptions. The Node main thread invokes poll()
// on every entry each tick.
struct ISubscriptionHandler {
    virtual ~ISubscriptionHandler() = default;
    virtual void poll() = 0;
};

template <typename T>
class SubscriptionHandler : public ISubscriptionHandler {
public:
    SubscriptionHandler(std::shared_ptr<::nros::Subscription<T>> inner,
                        callback_subscriber<T> cb, void * arg)
    : inner_(std::move(inner)), cb_(cb), arg_(arg) {}

    void poll() override
    {
        T msg;
        auto r = inner_->try_recv(msg);
        if (r.ok()) {
            cb_(&msg, arg_);
        }
        // TryAgain is silent; non-trivial errors throttle-log.
        // (Filtering by error code happens once nros::Result exposes
        // a stable TryAgain discriminant — see open-question list.)
    }

private:
    std::shared_ptr<::nros::Subscription<T>> inner_;
    callback_subscriber<T> cb_;
    void * arg_;
};

}  // namespace nros_shim
}  // namespace asi

class Node {
public:
    // Stack args kept for source-compat with legacy ctor; nros-cpp owns
    // its executor storage so these become no-ops here. The Node still
    // spins its own pthread for the polling loop (default attrs).
    Node(const std::string & node_name, void * stack_area, std::size_t stack_size)
    : node_name_(node_name)
    {
        (void)stack_area;
        (void)stack_size;
        auto r = ::nros::create_node(node_, node_name_.c_str());
        if (!r.ok()) {
            log_error("%s -> nros::create_node failed: %d. Exiting.\n",
                      node_name_.c_str(), r.raw());
            std::exit(1);
        }
        pthread_attr_init(&main_thread_attr_);
        timer_ = std::make_unique<Timer>(node_name_);
    }

    ~Node()
    {
        stop();
        pthread_attr_destroy(&main_thread_attr_);
    }

    int spin()
    {
        return pthread_create(&main_thread_, &main_thread_attr_,
                              main_thread_entry_, this);
    }

    void wait_for_completion() { pthread_join(main_thread_, nullptr); }

    void stop()
    {
        pthread_cancel(main_thread_);
        pthread_join(main_thread_, nullptr);
    }

    // nros routes types via the generated `nros::Publisher<M>` /
    // `nros::Subscription<M>` specialization — no runtime descriptor
    // needed. The optional / second `const void*` arg exists so legacy
    // controller call sites that still pass `&<msg>_desc` (sentinel
    // stubs from autoware_msgs/messages.hpp under ASI_USE_NANO_ROS)
    // compile unchanged through Phase 1.7. Arg is ignored.
    template <typename M>
    std::shared_ptr<asi::nros_shim::Publisher<M>>
    create_publisher(const std::string & topic_name,
                     const void * /*descriptor*/ = nullptr)
    {
        auto inner = std::make_shared<::nros::Publisher<M>>();
        auto r = node_.create_publisher(*inner, topic_name.c_str());
        if (!r.ok()) {
            log_error("%s -> create_publisher(%s) failed: %d\n",
                      node_name_.c_str(), topic_name.c_str(), r.raw());
            return nullptr;
        }
        pubs_.push_back(inner);
        return std::make_shared<asi::nros_shim::Publisher<M>>(inner);
    }

    template <typename T>
    bool create_subscription(const std::string & topic_name,
                             const void * /*descriptor*/,
                             callback_subscriber<T> cb, void * arg)
    {
        auto inner = std::make_shared<::nros::Subscription<T>>();
        auto r = node_.create_subscription(*inner, topic_name.c_str());
        if (!r.ok()) {
            log_error("%s -> create_subscription(%s) failed: %d\n",
                      node_name_.c_str(), topic_name.c_str(), r.raw());
            return false;
        }
        subs_.push_back(std::make_unique<asi::nros_shim::SubscriptionHandler<T>>(
            std::move(inner), cb, arg));
        return true;
    }

    // Parameter API — identical surface + semantics to the legacy
    // Node. Storage is Node-local because nros::ParameterServer
    // doesn't accept the vector-typed parameters MPC + PID rely on.
    template <typename ParamT>
    ParamT declare_parameter(const std::string & name,
                             const ParamT & default_value = ParamT{})
    {
        static_assert(std::is_constructible_v<param_type, ParamT>,
                      "Parameter type must be one of the supported types in param_type variant");

        auto it = parameters_map_.find(name);
        if (it == parameters_map_.end()) {
            parameters_map_[name] = default_value;
            return default_value;
        }
        try {
            return std::get<ParamT>(it->second);
        } catch (const std::bad_variant_access &) {
            log_warn("Parameter '%s' exists with different type. Not overwriting.\n",
                     name.c_str());
            return default_value;
        }
    }

    template <typename ParamT>
    ParamT get_parameter(const std::string & name) const
    {
        static_assert(std::is_constructible_v<param_type, ParamT>,
                      "Parameter type must be one of the supported types in param_type variant");

        auto p = search_parameter_(name);
        if (p) {
            try {
                return std::get<ParamT>(*p);
            } catch (const std::bad_variant_access &) {
                log_warn("%s -> get_parameter failed-1: %s\n",
                         node_name_.c_str(), name.c_str());
                return ParamT{};
            }
        }
        return ParamT{};
    }

    template <typename ParamT>
    bool set_parameter(const std::string & name, const ParamT & value)
    {
        static_assert(std::is_constructible_v<param_type, ParamT>,
                      "Parameter type must be one of the supported types in param_type variant");

        auto it = parameters_map_.find(name);
        if (it != parameters_map_.end()) {
            if (it->second.index() == param_type(value).index()) {
                it->second = value;
                return true;
            }
            log_warn("%s -> Cannot set parameter '%s' with different type\n",
                     node_name_.c_str(), name.c_str());
            return false;
        }
        return false;
    }

    inline bool has_parameter(const std::string & name) const
    {
        return parameters_map_.find(name) != parameters_map_.end();
    }

    inline std::string get_name() const { return node_name_; }

    bool create_timer(uint32_t period_ms, std::function<void()> callback)
    {
        if (!timer_) {
            log_error("%s -> Timer object not initialized!\n", node_name_.c_str());
            return false;
        }
        return timer_->start(period_ms, callback);
    }

    void stop_timer()
    {
        if (timer_) {
            timer_->stop();
            log_info("%s -> Timer stopped via Node request.\n", node_name_.c_str());
        } else {
            log_warn("%s -> Attempted to stop a non-initialized timer.\n",
                     node_name_.c_str());
        }
    }

private:
    std::string node_name_;
    ::nros::Node node_;

    std::unordered_map<std::string, param_type> parameters_map_;

    // Keep entities alive for as long as the Node lives. shared_ptr
    // because the user-facing Publisher<M> handle also holds one.
    std::vector<std::shared_ptr<void>> pubs_;
    std::vector<std::unique_ptr<asi::nros_shim::ISubscriptionHandler>> subs_;

    std::unique_ptr<Timer> timer_;

    pthread_t main_thread_;
    pthread_attr_t main_thread_attr_;

    static void * main_thread_entry_(void * arg)
    {
        Node * node = static_cast<Node *>(arg);
        while (true) {
            for (auto & sub : node->subs_) {
                sub->poll();
            }
            if (node->timer_) {
                node->timer_->execute();
            }
            usleep(1000);  // 1 ms cooperative tick; matches legacy cadence
        }
        return nullptr;
    }

    std::optional<param_type> search_parameter_(const std::string & name) const
    {
        auto it = parameters_map_.find(name);
        if (it != parameters_map_.end()) {
            return it->second;
        }
        return std::nullopt;
    }
};

// Expose the wrapper publisher type under the same `Publisher<T>` name
// controller code already uses. The legacy header puts it in the global
// namespace (via `common/dds/publisher.hpp`), so do the same here.
template <typename M>
using Publisher = asi::nros_shim::Publisher<M>;

#endif  // COMMON__NODE__NODE_NROS_HPP_
