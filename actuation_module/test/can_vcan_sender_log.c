// The nros log calls common/logger makes, for the can_vcan_sender host
// program: straight to stderr. The program takes the controller's headers but
// links no nros runtime archive (its log dispatcher would drag in the
// FreeRTOS kernel and the board entry).

#include <stdarg.h>
#include <stdio.h>

#include <rclc/log.h>

void rclc_log_init(void) {}

rclc_logger_t rclc_log_default_logger(void)
{
  static const char name[] = "can_vcan_sender";
  return name;
}

void rclc_log_emit_fmt(rclc_logger_t logger, rcl_log_severity_t severity, const char * fmt, ...)
{
  (void)logger;
  va_list args;
  va_start(args, fmt);
  fprintf(stderr, "[%d] ", (int)severity);
  vfprintf(stderr, fmt, args);
  fputc('\n', stderr);
  va_end(args);
}
