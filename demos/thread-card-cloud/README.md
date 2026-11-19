# Thread cloud builder capability

This directory's builder references `app/macos/Sources/App/NativeContentHost.swift`,
which is absent from this source tree. It cannot build a current preview. No
build/run command is advertised here. It has no product validation coverage.

Current cloud rendering is described by [PluginUI](../../app/macos/Sources/Shared/PluginUI/README.md)
and measured by the [external benchmark](../../tools/benchmarks/README.md).
