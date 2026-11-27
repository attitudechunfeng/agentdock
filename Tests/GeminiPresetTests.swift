import Foundation

func testGeminiPresetAllowed() {
    expect(geminiPresetAllowed("AGENT_PERMISSION_PRESET_DEFAULT"), "Default 下命令要你确认，可以借")
    expect(geminiPresetAllowed("AGENT_PERMISSION_PRESET_REQUEST_REVIEW"), "Request Review 可以借")
    expect(!geminiPresetAllowed("AGENT_PERMISSION_PRESET_TURBO"), "Turbo 下命令不经确认就能执行")
    expect(!geminiPresetAllowed("AGENT_PERMISSION_PRESET_AUTO"), "Auto 下命令不经确认就能执行")
    expect(!geminiPresetAllowed("AGENT_PERMISSION_PRESET_SOMETHING_NEW"), "不认识的预设不借")
    expect(!geminiPresetAllowed(""), "读不到预设不借")
}
