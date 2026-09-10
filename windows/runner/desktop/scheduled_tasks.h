#pragma once
#include <flutter/encodable_value.h>

// Schedules only wakeups. Timer state and execution stay in the Dart runtime.
void SyncScheduledTasks(const flutter::EncodableMap& payload);
