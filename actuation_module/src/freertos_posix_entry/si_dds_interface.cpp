// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// SI_DDS_INTERFACE on the nano-ros FreeRTOS POSIX lane (upstream #75).
//
// Upstream's POSIX binary picks its CycloneDDS network interface at run time:
// SI_DDS_INTERFACE, when set, overrides the compile-time value, so one released
// binary serves both loopback (CI, single-host domain bridge) and a LAN. The
// selector is an interface name ("lo"), a dotted-quad IPv4 address, or "auto".
//
// On this lane nano-ros owns the DDS session, and on hosted POSIX it creates
// the participant through Cyclone's own config loader, which reads
// CYCLONEDDS_URI. So the override is a CYCLONEDDS_URI fragment, set before the
// session opens: nano-ros's FreeRTOS runner calls the weak
// `nros_board_network_wait()` hook right before it opens the boot executor's
// session, and this strong definition replaces the no-op. A CYCLONEDDS_URI the
// operator already set is kept, and the fragment is appended after it (Cyclone
// parses comma-separated fragments in order, later ones on top).
//
// Without SI_DDS_INTERFACE nothing changes: Cyclone selects the interface
// itself (or from the operator's CYCLONEDDS_URI). The "Network interface" log
// line is printed in every case; upstream's release smoke job greps for it.

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "common/logger/logger.hpp"
using namespace common::logger;

namespace {

// Same rule as upstream's dds_selector_is_ipv4(): four dot-separated decimal
// octets, each 0-255 and at most three digits.
bool selector_is_ipv4(const char * s)
{
  int groups = 0, digits = 0, octet = 0;
  for (const char * p = s; ; ++p) {
    if (*p >= '0' && *p <= '9') {
      octet = octet * 10 + (*p - '0');
      if (++digits > 3 || octet > 255) return false;
    } else if (*p == '.' || *p == '\0') {
      if (digits == 0) return false;
      ++groups; digits = 0; octet = 0;
      if (*p == '\0') break;
    } else {
      return false;
    }
  }
  return groups == 4;
}

// An interface name or address goes into an XML attribute; refuse anything
// that could break out of it rather than escaping it.
bool selector_is_plain(const char * s)
{
  for (const char * p = s; *p != '\0'; ++p) {
    if (*p == '"' || *p == '<' || *p == '>' || *p == '&' || *p == '\'' || *p == ',') {
      return false;
    }
  }
  return true;
}

}  // namespace

extern "C" void nros_board_network_wait(void)
{
  const char * iface = std::getenv("SI_DDS_INTERFACE");
  if (iface == nullptr) {
    const char * uri = std::getenv("CYCLONEDDS_URI");
    if (uri != nullptr && uri[0] != '\0') {
      log_info("Network interface: from CYCLONEDDS_URI [default]\n");
    } else {
      log_info("Network interface: auto [default]\n");
    }
    return;
  }
  if (iface[0] == '\0' || std::strcmp(iface, "auto") == 0) {
    log_info("Network interface: auto [SI_DDS_INTERFACE]\n");
    return;
  }
  if (!selector_is_plain(iface)) {
    log_error("SI_DDS_INTERFACE=%s is not an interface name or IPv4 address; ignored\n", iface);
    return;
  }

  const bool by_ip = selector_is_ipv4(iface);
  std::string fragment =
    "<CycloneDDS><Domain Id=\"any\"><General><Interfaces><NetworkInterface ";
  fragment += by_ip ? "address=\"" : "name=\"";
  fragment += iface;
  fragment += "\" presence_required=\"true\"/></Interfaces></General></Domain></CycloneDDS>";

  std::string uri;
  if (const char * prev = std::getenv("CYCLONEDDS_URI"); prev != nullptr && prev[0] != '\0') {
    uri = prev;
    uri += ",";
  }
  uri += fragment;
  if (setenv("CYCLONEDDS_URI", uri.c_str(), 1) != 0) {
    log_error("SI_DDS_INTERFACE: could not set CYCLONEDDS_URI\n");
    return;
  }
  if (by_ip) {
    log_info("Network interface (by IP address): %s [SI_DDS_INTERFACE]\n", iface);
  } else {
    log_info("Network interface (by name): %s [SI_DDS_INTERFACE]\n", iface);
  }
}
