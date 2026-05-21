defmodule Web.Router do
  use Plug.Router

  plug Plug.Parsers, parsers: [:urlencoded], pass: ["*"]
  plug :match
  plug :dispatch

  get "/" do
    conn = Plug.Conn.assign(conn, :users, list_users())
    conn = Plug.Conn.assign(conn, :page_title, "Users")
    conn = Plug.Conn.assign(conn, :page_content, index_html(conn.assigns.users))
    send_resp(conn, 200, layout(conn))
  end

  get "/users/new" do
    conn = Plug.Conn.assign(conn, :page_title, "New User")
    conn = Plug.Conn.assign(conn, :page_content, form_html(nil))
    send_resp(conn, 200, layout(conn))
  end

  post "/users" do
    name = conn.params["name"] || ""
    email = conn.params["email"] || ""
    age = conn.params["age"] || ""

    age_int = if age == "", do: nil, else: String.to_integer(age)

    case Web.DB.query(
      "INSERT INTO dbo.users (name, email, age) VALUES (@1, @2, @3)",
      [
        %Tds.Parameter{name: "@1", value: name},
        %Tds.Parameter{name: "@2", value: email},
        %Tds.Parameter{name: "@3", value: age_int}
      ]
    ) do
      {:ok, _} ->
        conn = Plug.Conn.put_resp_header(conn, "location", "/")
        send_resp(conn, 302, "")

      {:error, reason} ->
        conn = Plug.Conn.assign(conn, :page_title, "New User")
        conn = Plug.Conn.assign(conn, :page_content, form_html(nil, error: inspect(reason), name: name, email: email, age: age))
        send_resp(conn, 400, layout(conn))
    end
  end

  get "/users/:id/edit" do
    id = String.to_integer(conn.params["id"])

    case Web.DB.query("SELECT id, name, email, age FROM dbo.users WHERE id = @1", [
      %Tds.Parameter{name: "@1", value: id}
    ]) do
      {:ok, %{rows: [[_id, name, email, age]]}} ->
        conn = Plug.Conn.assign(conn, :page_title, "Edit User")
        conn = Plug.Conn.assign(conn, :page_content, form_html(id, name: name, email: email, age: age))
        send_resp(conn, 200, layout(conn))

      _ ->
        conn = Plug.Conn.put_resp_header(conn, "location", "/")
        send_resp(conn, 302, "")
    end
  end

  post "/users/:id/update" do
    id = String.to_integer(conn.params["id"])
    name = conn.params["name"] || ""
    email = conn.params["email"] || ""
    age = conn.params["age"] || ""

    age_int = if age == "", do: nil, else: String.to_integer(age)

    Web.DB.query(
      "UPDATE dbo.users SET name = @1, email = @2, age = @3 WHERE id = @4",
      [
        %Tds.Parameter{name: "@1", value: name},
        %Tds.Parameter{name: "@2", value: email},
        %Tds.Parameter{name: "@3", value: age_int},
        %Tds.Parameter{name: "@4", value: id}
      ]
    )

    conn = Plug.Conn.put_resp_header(conn, "location", "/")
    send_resp(conn, 302, "")
  end

  post "/users/:id/delete" do
    id = String.to_integer(conn.params["id"])

    Web.DB.query("DELETE FROM dbo.users WHERE id = @1", [
      %Tds.Parameter{name: "@1", value: id}
    ])

    conn = Plug.Conn.put_resp_header(conn, "location", "/")
    send_resp(conn, 302, "")
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  defp list_users do
    case Web.DB.query("SELECT id, name, email, age FROM dbo.users ORDER BY id") do
      {:ok, %{rows: rows}} ->
        Enum.map(rows, fn [id, name, email, age] ->
          %{id: id, name: name, email: email, age: age}
        end)

      _ ->
        []
    end
  end

  defp index_html(users) do
    if users == [] do
      ~s|<p class="text-gray-500">No users found. <a href="/users/new" class="text-blue-600 hover:underline">Create one</a>.</p>|
    else
      rows = Enum.map(users, fn u ->
        ~s|<tr class="border-b hover:bg-gray-50">
          <td class="px-4 py-2">#{esc(u.id)}</td>
          <td class="px-4 py-2">#{esc(u.name)}</td>
          <td class="px-4 py-2">#{esc(u.email)}</td>
          <td class="px-4 py-2">#{esc(u.age)}</td>
          <td class="px-4 py-2">
            <a href="/users/#{u.id}/edit" class="text-blue-600 hover:underline mr-2">Edit</a>
            <form method="post" action="/users/#{u.id}/delete" class="inline">
              <button type="submit" class="text-red-600 hover:underline" onclick="return confirm('Delete #{esc(u.name)}?')">Delete</button>
            </form>
          </td>
        </tr>|
      end)
      |> Enum.join("\n")

      ~s|<a href="/users/new" class="inline-block bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700 mb-4">+ New User</a>
      <table class="w-full border-collapse">
        <thead>
          <tr class="bg-gray-100 border-b">
            <th class="px-4 py-2 text-left">ID</th>
            <th class="px-4 py-2 text-left">Name</th>
            <th class="px-4 py-2 text-left">Email</th>
            <th class="px-4 py-2 text-left">Age</th>
            <th class="px-4 py-2 text-left">Actions</th>
          </tr>
        </thead>
        <tbody>#{rows}</tbody>
      </table>|
    end
  end

  defp form_html(id, opts \\ []) do
    error = Keyword.get(opts, :error)
    name = Keyword.get(opts, :name, "")
    email = Keyword.get(opts, :email, "")
    age = Keyword.get(opts, :age, "")

    action = if id, do: "/users/#{id}/update", else: "/users"
    submit_label = if id, do: "Update User", else: "Create User"
    title = if id, do: "Edit User", else: "New User"

    error_html = if error, do: ~s|<div class="bg-red-100 text-red-700 p-2 rounded mb-4">#{esc(error)}</div>|, else: ""

    ~s|<h2 class="text-xl font-semibold mb-4">#{title}</h2>
    #{error_html}
    <form method="post" action="#{action}" class="max-w-md">
      <div class="mb-4">
        <label class="block text-sm font-medium mb-1">Name</label>
        <input type="text" name="name" value="#{esc(name)}" required class="w-full border rounded px-3 py-2">
      </div>
      <div class="mb-4">
        <label class="block text-sm font-medium mb-1">Email</label>
        <input type="email" name="email" value="#{esc(email)}" class="w-full border rounded px-3 py-2">
      </div>
      <div class="mb-4">
        <label class="block text-sm font-medium mb-1">Age</label>
        <input type="number" name="age" value="#{esc(age)}" class="w-full border rounded px-3 py-2">
      </div>
      <div class="flex gap-2">
        <button type="submit" class="bg-blue-600 text-white px-4 py-2 rounded hover:bg-blue-700">#{submit_label}</button>
        <a href="/" class="bg-gray-300 text-gray-700 px-4 py-2 rounded hover:bg-gray-400">Cancel</a>
      </div>
    </form>|
  end

  defp layout(conn) do
    ~s|<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>#{conn.assigns[:page_title]} - CDC Example</title>
  <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-gray-50 min-h-screen">
  <nav class="bg-blue-700 text-white px-6 py-3">
    <div class="max-w-4xl mx-auto flex items-center justify-between">
      <a href="/" class="text-xl font-bold">CDC Example</a>
      <a href="/users/new" class="bg-blue-600 hover:bg-blue-500 px-3 py-1 rounded text-sm">+ New User</a>
    </div>
  </nav>
  <main class="max-w-4xl mx-auto mt-6 px-4">
    #{conn.assigns[:page_content]}
  </main>
</body>
</html>|
  end

  defp esc(nil), do: ""
  defp esc(v) when is_integer(v), do: Integer.to_string(v)
  defp esc(v) do
    v
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace(~s["], "&quot;")
  end
end