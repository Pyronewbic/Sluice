package com.example;
import com.sun.net.httpserver.HttpServer;
import java.net.InetSocketAddress;
public class Main {
  public static void main(String[] a) throws Exception {
    HttpServer s = HttpServer.create(new InetSocketAddress("0.0.0.0", 8080), 0);
    s.createContext("/", e -> {
      byte[] b = "ok from java".getBytes();
      e.sendResponseHeaders(200, b.length);
      e.getResponseBody().write(b); e.getResponseBody().close();
    });
    s.start();
    Thread.currentThread().join();
  }
}
