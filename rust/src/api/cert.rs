//! Rust hooks the certification suite uses to probe the bridge and to crash
//! the app on purpose.

use std::sync::Mutex;

static HELD: Mutex<Vec<Vec<u8>>> = Mutex::new(Vec::new());

/// Smallest possible synchronous call, for timing a Dart to Rust round trip.
#[flutter_rust_bridge::frb(sync)]
pub fn ping(value: u32) -> u32 {
    value.wrapping_add(1)
}

/// Panics on a Rust worker thread. flutter_rust_bridge should turn this into
/// a Dart `PanicException` and the app should keep running.
pub fn panic_now() {
    panic!("certification: deliberate Rust panic");
}

/// Aborts the whole process, like a native crash in a plugin.
pub fn abort_now() {
    std::process::abort();
}

/// Allocates and touches `megabytes` more memory and keeps it, so repeated
/// calls walk the app towards AERA's memory limit. Returns the total held.
pub fn hold_memory(megabytes: u32) -> u64 {
    let mut block = vec![0u8; megabytes as usize * 1024 * 1024];
    for page in block.chunks_mut(4096) {
        page[0] = 1;
    }
    let mut held = HELD.lock().unwrap();
    held.push(block);
    held.iter().map(|b| b.len() as u64).sum()
}

/// Frees everything [`hold_memory`] kept.
pub fn release_memory() {
    HELD.lock().unwrap().clear();
}

/// Busy work split over `threads` Rust threads; returns elapsed microseconds.
pub fn spin_threads(threads: u32, iterations: u64) -> u64 {
    let start = std::time::Instant::now();
    std::thread::scope(|scope| {
        for t in 0..threads.max(1) {
            scope.spawn(move || {
                let mut x = t as u64 + 1;
                for i in 0..iterations {
                    x = x.wrapping_mul(6364136223846793005).wrapping_add(i);
                }
                std::hint::black_box(x);
            });
        }
    });
    start.elapsed().as_micros() as u64
}
/// Renders the Mandelbrot set as RGBA pixels, splitting rows across all CPUs.
/// `scale` is the width of the view in the complex plane.
pub fn fractal(
    width: u32,
    height: u32,
    center_x: f64,
    center_y: f64,
    scale: f64,
    max_iterations: u32,
) -> Vec<u8> {
    let (width, height) = (width.max(1) as usize, height.max(1) as usize);
    let mut pixels = vec![0u8; width * height * 4];
    let step = scale / width as f64;
    let top = center_y - step * height as f64 / 2.0;
    let left = center_x - scale / 2.0;
    let threads = std::thread::available_parallelism().map_or(1, |n| n.get());
    let rows_per_chunk = height.div_ceil(threads);
    std::thread::scope(|scope| {
        for (chunk_index, chunk) in pixels.chunks_mut(rows_per_chunk * width * 4).enumerate() {
            scope.spawn(move || {
                for (i, pixel) in chunk.chunks_exact_mut(4).enumerate() {
                    let x = i % width;
                    let y = chunk_index * rows_per_chunk + i / width;
                    let c = (left + x as f64 * step, top + y as f64 * step);
                    pixel.copy_from_slice(&colour(escape(c, max_iterations), max_iterations));
                }
            });
        }
    });
    pixels
}

/// Smooth escape count, or None inside the set.
fn escape((cr, ci): (f64, f64), max_iterations: u32) -> Option<f64> {
    let (mut zr, mut zi) = (0.0f64, 0.0f64);
    for n in 0..max_iterations {
        let (zr2, zi2) = (zr * zr, zi * zi);
        if zr2 + zi2 > 256.0 {
            return Some(n as f64 + 1.0 - ((zr2 + zi2).ln() / 2.0).ln() / std::f64::consts::LN_2);
        }
        zi = 2.0 * zr * zi + ci;
        zr = zr2 - zi2 + cr;
    }
    None
}

fn colour(escape: Option<f64>, max_iterations: u32) -> [u8; 4] {
    let Some(n) = escape else { return [8, 12, 16, 255] };
    let t = (n / max_iterations as f64).sqrt();
    let wave = |phase: f64| ((0.5 + 0.5 * (6.283 * (t * 3.0 + phase)).cos()) * 255.0) as u8;
    [wave(0.0), wave(0.15), wave(0.3), 255]
}

