#include <arpa/inet.h>
#include <sys/socket.h>
#include <unistd.h>

#include <algorithm>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>

namespace {

std::mutex record_mutex;

std::string env_or(const char* name, const std::string& fallback) {
    const char* value = std::getenv(name);
    return value != nullptr && *value != '\0' ? value : fallback;
}

std::string read_file(const std::string& path) {
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        return {};
    }
    std::ostringstream output;
    output << input.rdbuf();
    return output.str();
}

std::string wait_for_file(const std::string& path, int timeout_seconds) {
    const auto deadline = std::chrono::steady_clock::now() +
                          std::chrono::seconds(timeout_seconds);
    while (std::chrono::steady_clock::now() < deadline) {
        std::string value = read_file(path);
        if (!value.empty()) {
            return value;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    return {};
}

std::string utc_timestamp() {
    const std::time_t now = std::time(nullptr);
    std::tm utc{};
    gmtime_r(&now, &utc);
    char buffer[32]{};
    std::strftime(buffer, sizeof(buffer), "%Y-%m-%dT%H:%M:%SZ", &utc);
    return buffer;
}

std::string json_escape(const std::string& value) {
    std::ostringstream escaped;
    for (const unsigned char character : value) {
        switch (character) {
            case '\\':
                escaped << "\\\\";
                break;
            case '"':
                escaped << "\\\"";
                break;
            case '\n':
                escaped << "\\n";
                break;
            case '\r':
                escaped << "\\r";
                break;
            case '\t':
                escaped << "\\t";
                break;
            default:
                if (character < 0x20U) {
                    const char* digits = "0123456789abcdef";
                    escaped << "\\u00" << digits[(character >> 4U) & 0x0FU]
                            << digits[character & 0x0FU];
                } else {
                    escaped << static_cast<char>(character);
                }
        }
    }
    return escaped.str();
}

bool valid_token(const std::string& token) {
    if (token.empty() || token.size() > 128U) {
        return false;
    }
    return std::all_of(token.begin(), token.end(), [](unsigned char character) {
        return std::isalnum(character) != 0 || character == '-' ||
               character == '_' || character == '.';
    });
}

bool send_all(int fd, const std::string& data) {
    std::size_t sent = 0;
    while (sent < data.size()) {
        const ssize_t result = ::send(fd, data.data() + sent, data.size() - sent, 0);
        if (result <= 0) {
            return false;
        }
        sent += static_cast<std::size_t>(result);
    }
    return true;
}

void send_response(int fd,
                   int status,
                   const std::string& reason,
                   const std::string& content_type,
                   const std::string& body) {
    std::ostringstream response;
    response << "HTTP/1.1 " << status << ' ' << reason << "\r\n"
             << "Content-Type: " << content_type << "\r\n"
             << "Content-Length: " << body.size() << "\r\n"
             << "Connection: close\r\n\r\n"
             << body;
    send_all(fd, response.str());
}

bool read_request(int fd, std::string& method, std::string& path) {
    std::string request;
    char buffer[4096];
    while (request.find("\r\n\r\n") == std::string::npos && request.size() < 1048576U) {
        const ssize_t received = ::recv(fd, buffer, sizeof(buffer), 0);
        if (received <= 0) {
            return false;
        }
        request.append(buffer, static_cast<std::size_t>(received));
    }

    const std::size_t line_end = request.find("\r\n");
    if (line_end == std::string::npos) {
        return false;
    }
    std::istringstream first_line(request.substr(0, line_end));
    std::string target;
    std::string version;
    if (!(first_line >> method >> target >> version)) {
        return false;
    }

    const std::size_t query = target.find('?');
    path = target.substr(0, query);
    if (path.rfind("/api/", 0) == 0) {
        path.erase(0, 4);
    }
    return true;
}

std::string key_rotation_response() {
    return std::string{"{\"progress\":{\"current_key_rotation_id\":0,"}
           + "\"current_rotation_starting_epoch\":0,\"current_rotation_ending_epoch\":9},"
           + "\"key_rotation_state\":{\"validity_epochs\":10,\"initial_epoch_id\":0},"
           + "\"current_absolute_epoch_id\":0,\"current_epoch_start\":\""
           + utc_timestamp()
           + "\",\"epoch_duration\":{\"secs\":3600,\"nanos\":0}}";
}

bool store_traffic_receipt(const std::string& record_dir,
                           const std::string& token,
                           const std::string& source,
                           const std::string& path) {
    if (record_dir.empty()) {
        return true;
    }

    std::lock_guard<std::mutex> lock(record_mutex);
    std::error_code error;
    std::filesystem::create_directories(record_dir, error);
    if (error) {
        return false;
    }

    const std::string timestamp = utc_timestamp();
    const std::string body = std::string{"{\"received\":true,\"token\":\""}
        + json_escape(token) + "\",\"source\":\"" + json_escape(source)
        + "\",\"path\":\"" + json_escape(path) + "\",\"received_at\":\""
        + timestamp + "\"}\n";

    const std::filesystem::path destination =
        std::filesystem::path(record_dir) / (token + ".json");
    const std::filesystem::path temporary =
        std::filesystem::path(record_dir) /
        (token + ".tmp." + std::to_string(::getpid()));

    {
        std::ofstream output(temporary, std::ios::binary | std::ios::trunc);
        if (!output) {
            return false;
        }
        output << body;
        if (!output) {
            return false;
        }
    }

    std::filesystem::rename(temporary, destination, error);
    if (error) {
        std::filesystem::remove(destination, error);
        error.clear();
        std::filesystem::rename(temporary, destination, error);
    }
    if (error) {
        return false;
    }

    std::ofstream aggregate(std::filesystem::path(record_dir) / "requests.log",
                            std::ios::binary | std::ios::app);
    if (aggregate) {
        aggregate << timestamp << ' ' << source << ' ' << path << '\n';
    }
    return true;
}

void handle_connection(int fd,
                       const std::string& peer_address,
                       const std::string& network_file,
                       const std::string& rewarded_set_file,
                       const std::string& record_dir,
                       int topology_timeout) {
    std::string method;
    std::string path;
    if (!read_request(fd, method, path)) {
        ::close(fd);
        return;
    }

    if (method == "GET" && path.rfind("/traffic/", 0) == 0) {
        const std::string token = path.substr(std::string{"/traffic/"}.size());
        if (!valid_token(token)) {
            send_response(fd, 400, "Bad Request", "application/json",
                          "{\"error\":\"invalid traffic token\"}");
        } else if (!store_traffic_receipt(record_dir, token, peer_address, path)) {
            send_response(fd, 500, "Internal Server Error", "application/json",
                          "{\"error\":\"could not store traffic receipt\"}");
        } else {
            const std::string body = std::string{"{\"received\":true,\"token\":\""}
                + json_escape(token) + "\",\"source\":\""
                + json_escape(peer_address) + "\",\"path\":\""
                + json_escape(path) + "\"}";
            send_response(fd, 200, "OK", "application/json", body);
        }
    } else if (method == "GET" && path == "/v1/epoch/key-rotation-info") {
        send_response(fd, 200, "OK", "application/json", key_rotation_response());
    } else if (method == "POST" && path == "/v1/nym-nodes/refresh-described") {
        send_response(fd, 200, "OK", "application/json", "null");
    } else if (method == "GET" && path == "/v1/nym-nodes/described") {
        send_response(fd, 200, "OK", "application/json",
                      "{\"pagination\":{\"total\":0,\"page\":0,\"size\":0},\"data\":[]}");
    } else if (method == "GET" && path == "/v1/nym-nodes/rewarded-set") {
        std::string body = read_file(rewarded_set_file);
        if (body.empty()) {
            body = "{\"epoch_id\":0,\"entry_gateways\":[],\"exit_gateways\":[],"
                   "\"layer1\":[],\"layer2\":[],\"layer3\":[],\"standby\":[]}";
        }
        send_response(fd, 200, "OK", "application/json", body);
    } else if (method == "GET" &&
               (path == "/v2/unstable/nym-nodes/semi-skimmed" ||
                path == "/v1/nym-nodes/semi-skimmed" ||
                path == "/v1/nym-nodes/skimmed")) {
        std::string body = wait_for_file(network_file, topology_timeout);
        if (body.empty()) {
            body = "{\"metadata\":{\"absolute_epoch_id\":0,\"rotation_id\":0,"
                   "\"refreshed_at\":\"1970-01-01T00:00:00Z\"},\"nodes\":{"
                   "\"pagination\":{\"total\":0,\"page\":0,\"size\":0},\"data\":[]}}";
        }
        send_response(fd, 200, "OK", "application/json", body);
    } else if (method == "GET" && (path == "/health" || path == "/v1/health")) {
        send_response(fd, 200, "OK", "application/json", "{\"status\":\"ok\"}");
    } else if (method == "GET" && path == "/exit-policy") {
        send_response(fd, 200, "OK", "text/plain", "ExitPolicy accept *:*\n");
    } else {
        send_response(fd, 404, "Not Found", "application/json", "{\"error\":\"not found\"}");
    }

    ::shutdown(fd, SHUT_RDWR);
    ::close(fd);
}

}

int main() {
    std::signal(SIGPIPE, SIG_IGN);

    const std::string bind_address = env_or("NYM_LOCAL_API_BIND_ADDRESS", "127.0.0.1");
    const int port = std::stoi(env_or("NYM_LOCAL_API_PORT", "18080"));
    const std::string shared_dir = env_or("NYM_SHARED_DIR", "/run/nym-shared");
    const std::string network_file =
        env_or("NYM_LOCAL_API_NETWORK_FILE", shared_dir + "/network.json");
    const std::string rewarded_set_file =
        env_or("NYM_LOCAL_API_REWARDED_SET_FILE", shared_dir + "/rewarded-set.json");
    const std::string record_dir = env_or("NYM_TRAFFIC_RECORD_DIR", "");
    const int topology_timeout =
        std::stoi(env_or("NYM_LOCAL_API_TOPOLOGY_TIMEOUT", "120"));

    const int server = ::socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) {
        return 1;
    }

    int reuse = 1;
    ::setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(static_cast<uint16_t>(port));
    if (::inet_pton(AF_INET, bind_address.c_str(), &address.sin_addr) != 1 ||
        ::bind(server, reinterpret_cast<sockaddr*>(&address), sizeof(address)) != 0 ||
        ::listen(server, 64) != 0) {
        ::close(server);
        return 1;
    }

    while (true) {
        sockaddr_in peer{};
        socklen_t peer_length = sizeof(peer);
        const int connection = ::accept(
            server, reinterpret_cast<sockaddr*>(&peer), &peer_length);
        if (connection < 0) {
            if (errno == EINTR) {
                continue;
            }
            ::close(server);
            return 1;
        }

        char peer_buffer[INET_ADDRSTRLEN]{};
        const char* converted = ::inet_ntop(AF_INET, &peer.sin_addr,
                                            peer_buffer, sizeof(peer_buffer));
        const std::string peer_address = converted != nullptr ? converted : "unknown";
        std::thread(handle_connection, connection, peer_address, network_file,
                    rewarded_set_file, record_dir, topology_timeout).detach();
    }
}
