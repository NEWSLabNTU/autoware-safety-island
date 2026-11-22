// Copyright (c) 2026, NEWSLab NTU.
// SPDX-License-Identifier: Apache-2.0
//
// Zephyr's main(void) for a test program written with the hosted signature
// (renamed to asi_hosted_main by CMakeLists.txt), as nano-ros's ROS2_MAIN
// calls one from the board's entry.

int asi_hosted_main(int argc, char ** argv);

int main(void)
{
  static char name[] = "asi_test";
  static char * argv[] = {name, nullptr};
  return asi_hosted_main(1, argv);
}
