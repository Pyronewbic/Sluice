use std::io::Write;
use std::net::TcpListener;
use once_cell::sync::Lazy;
static MSG: Lazy<&'static str> = Lazy::new(|| "ok from rust\n");
fn main() {
    let l = TcpListener::bind("0.0.0.0:8080").expect("bind");
    for s in l.incoming() {
        if let Ok(mut s) = s {
            let b = *MSG;
            let _ = write!(s, "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}", b.len(), b);
        }
    }
}
