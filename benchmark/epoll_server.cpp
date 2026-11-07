// Upper bound for a native transport: an epoll loop that sends a fixed
// response without parsing the request. A real C++ transport would also have
// to parse HTTP and call back into Dart, so it can only be slower than this.
//
// Usage: epoll_server <port> <threads>
#include <arpa/inet.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/epoll.h>
#include <sys/socket.h>
#include <unistd.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <thread>
#include <vector>

static const char kResponse[] =
    "HTTP/1.1 200 OK\r\n"
    "content-type: text/plain; charset=utf-8\r\n"
    "x-frame-options: SAMEORIGIN\r\n"
    "x-xss-protection: 1; mode=block\r\n"
    "x-content-type-options: nosniff\r\n"
    "date: Fri, 06 Nov 2026 12:00:00 GMT\r\n"
    "content-length: 13\r\n"
    "\r\n"
    "Hello, World!";

static int make_listener(int port) {
  int fd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
  int on = 1;
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof(on));
  setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &on, sizeof(on));
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
  if (bind(fd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0 ||
      listen(fd, 4096) != 0) {
    perror("bind/listen");
    exit(1);
  }
  return fd;
}

static void run_loop(int listener) {
  int ep = epoll_create1(0);
  epoll_event ev{};
  ev.events = EPOLLIN;
  ev.data.fd = listener;
  epoll_ctl(ep, EPOLL_CTL_ADD, listener, &ev);

  std::vector<epoll_event> events(1024);
  char buffer[16384];
  for (;;) {
    int n = epoll_wait(ep, events.data(), events.size(), -1);
    for (int i = 0; i < n; i++) {
      int fd = events[i].data.fd;
      if (fd == listener) {
        int client;
        while ((client = accept4(listener, nullptr, nullptr, SOCK_NONBLOCK)) >= 0) {
          int on = 1;
          setsockopt(client, IPPROTO_TCP, TCP_NODELAY, &on, sizeof(on));
          epoll_event cev{};
          cev.events = EPOLLIN;
          cev.data.fd = client;
          epoll_ctl(ep, EPOLL_CTL_ADD, client, &cev);
        }
        continue;
      }
      ssize_t got = read(fd, buffer, sizeof(buffer));
      if (got > 0) {
        if (write(fd, kResponse, sizeof(kResponse) - 1) < 0) close(fd);
      } else if (got == 0) {
        close(fd);
      }
    }
  }
}

int main(int argc, char** argv) {
  int port = atoi(argv[1]);
  int threads = atoi(argv[2]);
  std::vector<std::thread> pool;
  std::vector<int> listeners;
  for (int i = 0; i < threads; i++) listeners.push_back(make_listener(port));
  for (int fd : listeners) pool.emplace_back(run_loop, fd);
  puts("READY");
  fflush(stdout);
  for (auto& t : pool) t.join();
}
