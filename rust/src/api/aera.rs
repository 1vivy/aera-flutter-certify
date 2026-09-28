//! AERA features for Dart. Each function here becomes a Dart function in
//! `lib/src/rust/api/aera.dart` when you run `flutter_rust_bridge_codegen
//! generate`. Add your own Rust next to this file in `api/`.

use std::path::PathBuf;

#[flutter_rust_bridge::frb(init)]
pub fn init_app() {
    flutter_rust_bridge::setup_default_user_utils();
}

/// True inside AERA Recovery, false on a PC.
#[flutter_rust_bridge::frb(sync)]
pub fn in_recovery() -> bool {
    aera_sdk::env::in_recovery()
}

/// AERA's selected language, such as `de_DE`.
#[flutter_rust_bridge::frb(sync)]
pub fn recovery_locale() -> String {
    aera_sdk::env::locale()
}

pub struct StorageDirs {
    /// Private, survives reboots.
    pub app_data: String,
    /// Shared with the user as `/sdcard/AERA/Downloads`.
    pub downloads: String,
    /// In RAM, cleared when the app closes.
    pub temp: String,
}

#[flutter_rust_bridge::frb(sync)]
pub fn storage_dirs() -> StorageDirs {
    let text = |p: PathBuf| p.to_string_lossy().into_owned();
    StorageDirs {
        app_data: text(aera_sdk::storage::app_data_dir()),
        downloads: text(aera_sdk::storage::downloads_dir()),
        temp: text(aera_sdk::storage::temp_dir()),
    }
}

pub struct DeviceInfo {
    pub kernel: String,
    pub machine: String,
    pub cpu_count: u32,
    pub total_ram_bytes: u64,
    pub free_ram_bytes: u64,
    pub uptime_seconds: u64,
}

pub fn device_info() -> DeviceInfo {
    let info = aera_sdk::device::info();
    DeviceInfo {
        kernel: info.kernel,
        machine: info.machine,
        cpu_count: info.cpu_count,
        total_ram_bytes: info.total_ram_bytes,
        free_ram_bytes: info.free_ram_bytes,
        uptime_seconds: info.uptime_seconds,
    }
}

/// Plays a sine tone through the phone's speaker. Returns once the bridge
/// has taken the samples. Fails on a PC, where there is no AERA audio bridge.
pub fn play_tone(frequency_hz: f32, milliseconds: u32, volume: f32) -> anyhow::Result<()> {
    let mut output = aera_sdk::audio::AudioOutput::connect()?;
    output.write(&aera_sdk::audio::tone(frequency_hz, milliseconds, volume))?;
    Ok(())
}

/// Plays interleaved 48 kHz stereo 16-bit samples through the speaker.
pub fn play_pcm(samples: Vec<i16>) -> anyhow::Result<()> {
    let mut output = aera_sdk::audio::AudioOutput::connect()?;
    output.write(&samples)?;
    Ok(())
}
