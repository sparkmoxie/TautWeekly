import http from "node:http";

const listenAddress = "127.0.0.1";
const listenPort = 18181;
const apiKey = "fictional-browser-qa-api-key";

const users = Array.from({ length: 78 }, (_, index) => ({
  user_id: String(index + 1),
  friendly_name: index === 0 ? "Fictional Admin" : `Fictional Viewer ${String(index + 1).padStart(2, "0")}`,
  email: index === 0
    ? "viewer@example.com"
    : index === 1
      ? "unmatched-legacy@example.org"
      : index === 2
        ? ""
        : `viewer${index + 1}@example.org`,
  is_active: 1,
  is_archived: index === 3 ? 1 : 0,
  deleted_user: index === 4 ? 1 : 0,
  do_notify: 1,
  is_admin: index === 0 ? 1 : 0,
}));
users[3].friendly_name = "Fictional Archived Viewer";
users[4].friendly_name = "Fictional Deleted Viewer";
users[5].friendly_name = "Fictional Inactive Viewer";
users[5].is_active = 0;

const libraries = [
  { section_id: "1", section_name: "Fictional Movies", section_type: "movie", is_active: 1, count: 40 },
  { section_id: "2", section_name: "Fictional Shows", section_type: "show", is_active: 1, count: 20 },
  { section_id: "3", section_name: "Fictional Archived Family", section_type: "movie", is_active: 1, count: 18 },
];
const includeArchived = (target) => target.searchParams.get("include_archived") === "1";

const server = http.createServer((request, response) => {
  const target = new URL(request.url || "/", `http://${listenAddress}:${listenPort}`);
  if (target.pathname !== "/api/v2" || request.headers["x-api-key"] !== apiKey || [...target.searchParams.keys()].some((name) => name.toLowerCase() === "apikey")) {
    response.writeHead(401, { "content-type": "text/plain; charset=utf-8" });
    response.end("unauthorized");
    return;
  }

  let data;
  switch (target.searchParams.get("cmd")) {
    case "get_libraries":
      // The real live-Plex endpoint omits Tautulli archive status.
      data = libraries;
      break;
    case "get_library_names":
      data = libraries.map(({ section_id, section_name, section_type }) => ({ section_id, section_name, section_type, is_archived: section_id === "3" ? 1 : 0 }))
        .filter((library) => includeArchived(target) || !library.is_archived);
      break;
    case "get_user_names":
      data = users.filter((user) => !user.deleted_user && (includeArchived(target) || !user.is_archived))
        .map(({ user_id, friendly_name, is_archived }) => ({ user_id, friendly_name, is_archived }));
      break;
    case "get_users":
      data = users.filter((user) => !user.deleted_user).map((user) => {
        if (!["1", "2"].includes(user.user_id)) return user;
        const { email: _email, ...withoutEmail } = user;
        return withoutEmail;
      });
      break;
    case "get_users_table":
      if (target.searchParams.get("start") !== "0" || target.searchParams.get("length") !== "2000") {
        response.writeHead(400, { "content-type": "text/plain; charset=utf-8" });
        response.end("invalid fixture table window");
        return;
      }
      data = { data: users.filter((user) => (target.searchParams.get("include_deleted") === "1" || !user.deleted_user) && (includeArchived(target) || !user.is_archived)) };
      break;
    default:
      response.writeHead(400, { "content-type": "text/plain; charset=utf-8" });
      response.end("unsupported fixture command");
      return;
  }

  response.writeHead(200, { "content-type": "application/json; charset=utf-8" });
  response.end(JSON.stringify({ response: { result: "success", data } }));
});

server.listen(listenPort, listenAddress);

for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => server.close(() => process.exit(0)));
}
