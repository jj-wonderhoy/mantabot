require 'websocket-client-simple'
require 'sqlite3'
require 'json'
require 'net/http'
require 'uri'
require 'webrick'

# --- Configuration ---
BOT_TOKEN = 'PLACEHOLDER'
BOT_ID = 'PLACEHOLDER'
FLUXER_API = 'https://api.fluxer.app/v1'
GATEWAY_URL = 'wss://gateway.fluxer.app/?v=1&encoding=json'
VRCHAT_API_BASE = 'https://api.vrchat.cloud/api/1'

# Bot Alt Account Auth Cookie (Manta-Rae)
VRCHAT_AUTH_COOKIE = 'PLACEHOLDER'

# Shared Log Buffer for Admin Panel
$bot_logs = []
def log_event(message)
  timestamp = Time.now.strftime('%Y-%m-%d %H:%M:%S')
  entry = "[#{timestamp}] #{message}"
  puts entry
  $bot_logs.unshift(entry)
  $bot_logs.pop if $bot_logs.length > 50 # Keep last 50 logs
end

# --- Setup SQLite Database ---
DB = SQLite3::Database.new('fluxer_vrchat.db')
DB.execute <<-SQL
  CREATE TABLE IF NOT EXISTS pending (
    fluxer_id TEXT PRIMARY KEY,
    vrchat_id TEXT,
    vrchat_username TEXT,
    code TEXT,
    channel_id TEXT,
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );
SQL

DB.execute <<-SQL
  CREATE TABLE IF NOT EXISTS verified (
    fluxer_id TEXT PRIMARY KEY,
    vrchat_id TEXT,
    vrchat_username TEXT,
    linked_at DATETIME DEFAULT CURRENT_TIMESTAMP
  );
SQL

DB.execute <<-SQL
  CREATE TABLE IF NOT EXISTS settings (
    guild_id TEXT PRIMARY KEY,
    verified_role_id TEXT,
    adult_role_id TEXT,
    announcement_channel_id TEXT
  );
SQL

DB.execute <<-SQL
  CREATE TABLE IF NOT EXISTS cooldowns (
    identifier TEXT PRIMARY KEY,
    expires_at DATETIME
  );
SQL

# --- Helper: Send Embed to Fluxer Channel / DM ---
def send_fluxer_embed(channel_id, embed_payload)
  begin
    uri = URI("#{FLUXER_API}/channels/#{channel_id}/messages")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Post.new(uri.path, {
      'Authorization' => "Bot #{BOT_TOKEN}",
      'Content-Type' => 'application/json'
    })
    request.body = { embeds: [embed_payload] }.to_json
    http.request(request)
  rescue => e
    log_event("API Error (send_fluxer_embed): #{e.message}")
  end
end

# --- Helper: Create DM Channel with User ---
def create_dm_channel(user_id)
  begin
    uri = URI("#{FLUXER_API}/users/@me/channels")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Post.new(uri.path, {
      'Authorization' => "Bot #{BOT_TOKEN}",
      'Content-Type' => 'application/json'
    })
    request.body = { recipient_id: user_id }.to_json
    response = http.request(request)
    return nil unless response.is_a?(Net::HTTPSuccess)
    JSON.parse(response.body)['id']
  rescue => e
    log_event("API Error (create_dm_channel): #{e.message}")
    nil
  end
end

# --- Helper: Assign Role on Fluxer Guild ---
def assign_fluxer_role(guild_id, user_id, role_id)
  return unless guild_id && role_id
  begin
    uri = URI("#{FLUXER_API}/guilds/#{guild_id}/members/#{user_id}/roles/#{role_id}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Put.new(uri.path, {
      'Authorization' => "Bot #{BOT_TOKEN}"
    })
    http.request(request)
  rescue => e
    log_event("API Error (assign_fluxer_role): #{e.message}")
  end
end

# --- Helper: VRChat API Fetchers ---
def fetch_vrchat_user_by_name(username)
  begin
    uri = URI("#{VRCHAT_API_BASE}/users?search=#{URI.encode_www_form_component(username)}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Get.new(uri.request_uri, {
      'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) VRChatBot/1.0',
      'Cookie' => VRCHAT_AUTH_COOKIE
    })
    response = http.request(request)
    return nil unless response.is_a?(Net::HTTPSuccess)

    users = JSON.parse(response.body)
    users.first
  rescue => e
    log_event("VRChat API Error (by_name): #{e.message}")
    nil
  end
end

def fetch_vrchat_user_by_id(user_id)
  begin
    uri = URI("#{VRCHAT_API_BASE}/users/#{user_id}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    request = Net::HTTP::Get.new(uri.request_uri, {
      'User-Agent' => 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) VRChatBot/1.0',
      'Cookie' => VRCHAT_AUTH_COOKIE
    })
    response = http.request(request)
    return nil unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  rescue => e
    log_event("VRChat API Error (by_id): #{e.message}")
    nil
  end
end

# --- Background Worker Thread for 5-Min Timeouts ---
Thread.new do
  loop do
    sleep 30
    begin
      expired_rows = DB.execute("SELECT fluxer_id, channel_id FROM pending WHERE datetime(created_at, '+5 minutes') < datetime('now')")
      expired_rows.each do |fluxer_id, channel_id|
        DB.execute("DELETE FROM pending WHERE fluxer_id = ?", [fluxer_id])
        dm_channel = create_dm_channel(fluxer_id) || channel_id
        if dm_channel
          send_fluxer_embed(dm_channel, {
            title: "⌛ Link Request Expired",
            description: "<@#{fluxer_id}> Your VRChat link request timed out after 5 minutes. Use `@Manta link <name/url>` to try again.",
            color: 0xE74C3C
          })
          log_event("Verification timeout expired for Fluxer ID: #{fluxer_id}")
        end
      end
    rescue => e
      log_event("Background Worker Error: #{e.message}")
    end
  end
end

# --- Start HTML Admin Panel Web Server on Port 30115 (Extended Controls + Broadcast) ---
Thread.new do
  server = WEBrick::HTTPServer.new(Port: 30115, AccessLog: [], Logger: WEBrick::Log.new(nil, WEBrick::Log::WARN))

  server.mount_proc '/' do |req, res|
    cookies = req.cookies.map { |c| [c.name, c.value] }.to_h
    is_authenticated = cookies['admin_auth'] == 'manta_logged_in'

    # Handle Login Form Submission
    if req.request_method == 'POST' && req.path == '/login'
      body = req.body.to_s
      user = body.match(/username=([^&]+)/)&.[](1)
      pass = body.match(/password=([^&]+)/)&.[](1)
      
      if user == 'manta' && pass == 'manta'
        res.cookies << WEBrick::Cookie.new('admin_auth', 'manta_logged_in')
        res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/')
      else
        res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/login?error=1')
      end
      next
    end

    # Handle Logout
    if req.path == '/logout'
      cookie = WEBrick::Cookie.new('admin_auth', '')
      cookie.max_age = 0
      res.cookies << cookie
      res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/login')
      next
    end

    # Serve Login Page if Not Authenticated
    if !is_authenticated || req.path == '/login'
      error_msg = req.query['error'] ? '<p style="color: #ef4444; text-align: center;">Invalid username or password.</p>' : ''
      res.body = <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <title>Manta Admin Login</title>
            <style>
                body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #f8fafc; display: flex; justify-content: center; align-items: center; height: 100vh; margin: 0; }
                .login-box { background: #1e293b; padding: 40px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.5); width: 300px; }
                h1 { color: #38bdf8; text-align: center; margin-top: 0; font-size: 22px; }
                input { width: 100%; padding: 10px; margin: 10px 0; border-radius: 4px; border: 1px solid #475569; background: #0f172a; color: white; box-sizing: border-box; }
                button { width: 100%; background: #38bdf8; color: #0f172a; border: none; padding: 10px; font-weight: bold; border-radius: 4px; cursor: pointer; margin-top: 10px; }
                button:hover { background: #0ea5e9; }
            </style>
        </head>
        <body>
            <div class="login-box">
                <h1>Manta By JJ Otori</h1>
                #{error_msg}
                <form action="/login" method="POST">
                    <input type="text" name="username" placeholder="Username" required>
                    <input type="password" name="password" placeholder="Password" required>
                    <button type="submit">Log In</button>
                </form>
            </div>
        </body>
        </html>
      HTML
      res['Content-Type'] = 'text/html'
      next
    end

    # Handle Admin Actions via POST
    if req.request_method == 'POST'
      body = req.body.to_s
      if body.include?('action=unlink')
        fluxer_to_remove = body.match(/fluxer_id=([^&]+)/)&.[](1)
        if fluxer_to_remove
          f_id = URI.decode_www_form_component(fluxer_to_remove)
          vrc_row = DB.get_first_row("SELECT vrchat_id FROM verified WHERE fluxer_id = ?", [f_id])
          DB.execute("DELETE FROM verified WHERE fluxer_id = ?", [f_id])
          DB.execute("INSERT OR REPLACE INTO cooldowns (identifier, expires_at) VALUES (?, datetime('now', '+2 hours'))", [f_id])
          DB.execute("INSERT OR REPLACE INTO cooldowns (identifier, expires_at) VALUES (?, datetime('now', '+2 hours'))", [vrc_row[0]]) if vrc_row
          log_event("Admin manually unlinked Fluxer ID: #{f_id}")
        end
      elsif body.include?('action=link')
        f_id = body.match(/fluxer_id=([^&]+)/)&.[](1)
        v_name = body.match(/vrchat_username=([^&]+)/)&.[](1)
        if f_id && v_name
          decoded_name = URI.decode_www_form_component(v_name)
          vrc_brief = fetch_vrchat_user_by_name(decoded_name)
          if vrc_brief
            DB.execute("INSERT OR REPLACE INTO verified (fluxer_id, vrchat_id, vrchat_username) VALUES (?, ?, ?)", [URI.decode_www_form_component(f_id), vrc_brief['id'], vrc_brief['displayName']])
            log_event("Admin manually linked Fluxer ID #{f_id} to VRChat user #{vrc_brief['displayName']}")
          end
        end
      elsif body.include?('action=clear_pending')
        DB.execute("DELETE FROM pending")
        log_event("Admin cleared all pending verification requests.")
      elsif body.include?('action=delete_setting')
        g_id = body.match(/guild_id=([^&]+)/)&.[](1)
        if g_id
          DB.execute("DELETE FROM settings WHERE guild_id = ?", [URI.decode_www_form_component(g_id)])
          log_event("Admin removed role settings for guild #{g_id}")
        end
      elsif body.include?('action=broadcast')
        msg_text = body.match(/broadcast_message=([^&]+)/)&.[](1)
        if msg_text
          decoded_msg = URI.decode_www_form_component(msg_text)
          channels = DB.execute("SELECT DISTINCT channel_id FROM pending UNION SELECT DISTINCT guild_id FROM settings").flatten
          channels.each do |target_id|
            send_fluxer_embed(target_id, {
              title: "📢 Manta Broadcast Announcement",
              description: decoded_msg,
              color: 0x9B59B6
            })
          end
          log_event("Broadcast sent to #{channels.length} destinations: #{decoded_msg}")
        end
      end
      res.set_redirect(WEBrick::HTTPStatus::SeeOther, '/')
      next
    end

    verified_users = DB.execute("SELECT fluxer_id, vrchat_id, vrchat_username, linked_at FROM verified ORDER BY linked_at DESC")
    guild_settings = DB.execute("SELECT guild_id, verified_role_id, adult_role_id FROM settings")
    pending_count = DB.get_first_value("SELECT COUNT(*) FROM pending") || 0
    verified_count = verified_users.length

    rows_html = verified_users.map { |row|
      "<tr><td>#{row[0]}</td><td><strong>#{row[2]}</strong></td><td><code>#{row[1]}</code></td><td>#{row[3]}</td><td><form method='POST' style='margin:0;'><input type='hidden' name='action' value='unlink'><input type='hidden' name='fluxer_id' value='#{row[0]}'><button type='submit' style='background:#ef4444; color:white; border:none; padding:5px 10px; border-radius:4px; cursor:pointer;'>Unlink</button></form></td></tr>"
    }.join

    settings_rows_html = guild_settings.map { |row|
      "<tr><td><code>#{row[0]}</code></td><td><code>#{row[1]}</code></td><td><code>#{row[2] || 'None'}</code></td><td><form method='POST' style='margin:0;'><input type='hidden' name='action' value='delete_setting'><input type='hidden' name='guild_id' value='#{row[0]}'><button type='submit' style='background:#ef4444; color:white; border:none; padding:5px 10px; border-radius:4px; cursor:pointer;'>Delete</button></form></td></tr>"
    }.join

    logs_html = $bot_logs.map { |l| "<div>#{l}</div>" }.join

    res.body = <<~HTML
      <!DOCTYPE html>
      <html lang="en">
      <head>
          <meta charset="UTF-8">
          <title>Manta Bot Admin Panel</title>
          <style>
              body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 30px; }
              .container { max-width: 1100px; margin: auto; background: #1e293b; padding: 30px; border-radius: 12px; box-shadow: 0 4px 20px rgba(0,0,0,0.5); }
              .header { display: flex; justify-content: space-between; align-items: center; }
              h1 { color: #38bdf8; margin: 0; }
              .logout-btn { background: #ef4444; color: white; padding: 8px 14px; text-decoration: none; border-radius: 4px; font-size: 14px; font-weight: bold; }
              .logout-btn:hover { background: #dc2626; }
              .stats { display: flex; gap: 20px; margin-top: 20px; margin-bottom: 30px; }
              .card { background: #334155; padding: 20px; border-radius: 8px; flex: 1; text-align: center; }
              .card h2 { margin: 0 0 10px 0; color: #cbd5e1; font-size: 16px; }
              .card p { margin: 0; font-size: 28px; font-weight: bold; color: #38bdf8; }
              table { width: 100%; border-collapse: collapse; margin-top: 10px; background: #0f172a; border-radius: 8px; overflow: hidden; }
              th, td { padding: 12px 15px; text-align: left; border-bottom: 1px solid #334155; }
              th { background: #475569; color: #f1f5f9; }
              tr:hover { background: #1e293b; }
              code { background: #334155; padding: 3px 6px; border-radius: 4px; font-size: 13px; color: #cbd5e1; }
              .section { margin-top: 30px; background: #334155; padding: 20px; border-radius: 8px; }
              .form-group { display: flex; gap: 10px; margin-top: 10px; }
              input[type="text"], input[type="search"] { padding: 10px; border-radius: 4px; border: 1px solid #475569; background: #0f172a; color: white; flex: 1; box-sizing: border-box; }
              button.btn { background: #38bdf8; color: #0f172a; border: none; padding: 10px 20px; font-weight: bold; border-radius: 4px; cursor: pointer; }
              button.btn:hover { background: #0ea5e9; }
              button.btn-warn { background: #f59e0b; color: #0f172a; border: none; padding: 10px 15px; font-weight: bold; border-radius: 4px; cursor: pointer; }
              button.btn-warn:hover { background: #d97706; }
              button.btn-broadcast { background: #9b59b6; color: white; border: none; padding: 10px 20px; font-weight: bold; border-radius: 4px; cursor: pointer; }
              button.btn-broadcast:hover { background: #8e44ad; }
              .logs { background: #020617; padding: 15px; border-radius: 6px; font-family: monospace; font-size: 13px; color: #34d399; max-height: 200px; overflow-y: auto; margin-top: 10px; }
          </style>
          <script>
              function filterTable() {
                  let input = document.getElementById('searchInput').value.toLowerCase();
                  let rows = document.querySelectorAll('#verifiedTable tbody tr');
                  rows.forEach(row => {
                      let text = row.innerText.toLowerCase();
                      row.style.display = text.includes(input) ? '' : 'none';
                  });
              }
          </script>
      </head>
      <body>
          <div class="container">
              <div class="header">
                  <h1>Manta Console</h1>
                  <a href="/logout" class="logout-btn">Log Out</a>
              </div>
              
              <div class="stats">
                  <div class="card">
                      <h2>Total Verified Users</h2>
                      <p>#{verified_count}</p>
                  </div>
                  <div class="card">
                      <h2>Pending Requests</h2>
                      <p>#{pending_count}</p>
                      <form method="POST" style="margin-top: 10px;">
                          <input type="hidden" name="action" value="clear_pending">
                          <button type="submit" class="btn-warn" style="font-size: 12px; padding: 6px 12px;">Clear All Pending</button>
                      </form>
                  </div>
              </div>

              <div class="section">
                  <h2>📢 Global Broadcast Announcement</h2>
                  <p style="color: #94a3b8; font-size: 14px; margin-top: 0;">Send an official announcement embed to all connected servers and active channels.</p>
                  <form method="POST" class="form-group">
                      <input type="hidden" name="action" value="broadcast">
                      <input type="text" name="broadcast_message" placeholder="Type announcement message here..." required>
                      <button type="submit" class="btn-broadcast">Broadcast Now</button>
                  </form>
              </div>

              <div class="section">
                  <h2>Manual Account Link</h2>
                  <form method="POST" class="form-group">
                      <input type="hidden" name="action" value="link">
                      <input type="text" name="fluxer_id" placeholder="Fluxer User ID" required>
                      <input type="text" name="vrchat_username" placeholder="VRChat Display Name" required>
                      <button type="submit" class="btn">Link Account</button>
                  </form>
              </div>

              <div class="section">
                  <h2>Server Verification Roles Config</h2>
                  <table>
                      <thead>
                          <tr>
                              <th>Guild ID</th>
                              <th>Verified Role ID</th>
                              <th>Adult Role ID</th>
                              <th>Action</th>
                          </tr>
                      </thead>
                      <tbody>
                          #{settings_rows_html.empty? ? '<tr><td colspan="4" style="text-align:center; color:#94a3b8;">No server configurations stored yet.</td></tr>' : settings_rows_html}
                      </tbody>
                  </table>
              </div>

              <div class="section">
                  <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 10px;">
                      <h2 style="margin: 0;">Verified Accounts Database</h2>
                      <input type="search" id="searchInput" onkeyup="filterTable()" placeholder="Search verified users..." style="max-width: 300px;">
                  </div>
                  <table id="verifiedTable">
                      <thead>
                          <tr>
                              <th>Fluxer ID</th>
                              <th>VRChat Display Name</th>
                              <th>VRChat User ID</th>
                              <th>Linked At</th>
                              <th>Actions</th>
                          </tr>
                      </thead>
                      <tbody>
                          #{rows_html.empty? ? '<tr><td colspan="5" style="text-align:center; color:#94a3b8;">No verified accounts yet.</td></tr>' : rows_html}
                      </tbody>
                  </table>
              </div>

              <div class="section">
                  <h2>Live Bot Activity Logs</h2>
                  <div class="logs">
                      #{logs_html.empty? ? '<div>No logs recorded yet.</div>' : logs_html}
                  </div>
              </div>
          </div>
      </body>
      </html>
    HTML
    res['Content-Type'] = 'text/html'
  end

  trap('INT') { server.shutdown }
  log_event("Admin Panel started on http://localhost:30115 (Custom Login: manta / manta)")
  server.start
end

# --- Command Router ---
def handle_command(channel_id, author_id, args, guild_id = nil)
  sub_command = args[0]&.downcase

  case sub_command
  when 'help'
    embed = {
      title: "📖 Manta Bot Commands",
      description: "Here are all available commands you can use with Manta:",
      color: 0x3498DB,
      fields: [
        { name: "`@Manta link <name or URL>`", value: "Start linking your VRChat account by putting a verification code in your status.", inline: false },
        { name: "`@Manta verify`", value: "Complete verification after updating your VRChat status.", inline: false },
        { name: "`@Manta profile`", value: "View your currently linked VRChat account.", inline: false },
        { name: "`@Manta whois [@user or name]`", value: "Look up a user's linked VRChat profile and stats.", inline: false },
        { name: "`@Manta unlink`", value: "Unlink your VRChat account (triggers a 2-hour cooldown before re-linking).", inline: false },
        { name: "`@Manta setup <verified_role_id> [adult_role_id]`", value: "Configure verification roles for this server (Admin only).", inline: false }
      ]
    }
    send_fluxer_embed(channel_id, embed)

  when 'setup'
    unless guild_id
      embed = {
        title: "⚠️ Server Only Command",
        description: "<@#{author_id}> The setup command can only be used inside a server channel.",
        color: 0xF1C40F
      }
      return send_fluxer_embed(channel_id, embed)
    end

    verified_role_id = args[1]
    adult_role_id = args[2]

    if verified_role_id.nil?
      embed = {
        title: "⚙️ Setup Instructions",
        description: "<@#{author_id}> Configure verification roles for this server:\n`@Manta setup <verified_role_id> [adult_role_id]`",
        color: 0x3498DB
      }
      return send_fluxer_embed(channel_id, embed)
    end

    DB.execute("INSERT OR REPLACE INTO settings (guild_id, verified_role_id, adult_role_id) VALUES (?, ?, ?)", [guild_id, verified_role_id, adult_role_id])
    log_event("Guild #{guild_id} updated roles: Verified=#{verified_role_id}, Adult=#{adult_role_id}")

    embed = {
      title: "✅ Setup Successful",
      description: "<@#{author_id}> Server verification roles successfully configured!\n• **Verified Role ID:** `#{verified_role_id}`\n• **18+ Adult Role ID:** `#{adult_role_id || 'None'}`",
      color: 0x2ECC71
    }
    send_fluxer_embed(channel_id, embed)

  when 'link'
    input_str = args[1..-1]&.join(' ')
    if input_str.nil? || input_str.empty?
      embed = {
        title: "⚠️ Missing Input",
        description: "<@#{author_id}> Please specify your VRChat display name or profile URL!\nUsage:\n`@Manta link YourName`\n`@Manta link https://vrchat.com/home/user/usr_...`",
        color: 0xF1C40F
      }
      return send_fluxer_embed(channel_id, embed)
    end

    cleaned_input = input_str.gsub(/[\s\r\n]+/, '')
    id_match = cleaned_input.match(/(usr_[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})/)
    
    vrc_user = nil
    if id_match
      vrc_user_id = id_match[1]
      vrc_user = fetch_vrchat_user_by_id(vrc_user_id)
    else
      vrc_brief = fetch_vrchat_user_by_name(input_str)
      vrc_user = fetch_vrchat_user_by_id(vrc_brief['id']) if vrc_brief
    end

    unless vrc_user
      embed = {
        title: "❌ User Not Found",
        description: "<@#{author_id}> Could not find a VRChat user matching `#{input_str}`. Check your spelling or use your profile URL.",
        color: 0xE74C3C
      }
      return send_fluxer_embed(channel_id, embed)
    end

    # Check 2-hour cooldown for author or target VRChat ID
    cooldown_check = DB.get_first_value("SELECT 1 FROM cooldowns WHERE identifier IN (?, ?) AND expires_at > datetime('now')", [author_id, vrc_user['id']])
    if cooldown_check
      embed = {
        title: "⏳ Cooldown Active",
        description: "<@#{author_id}> You or this VRChat account are currently on a 2-hour cooldown after unlinking. Please wait before linking again.",
        color: 0xF1C40F
      }
      return send_fluxer_embed(channel_id, embed)
    end

    code = "MANTA-#{rand(100000..999999)}"

    DB.execute("INSERT OR REPLACE INTO pending (fluxer_id, vrchat_id, vrchat_username, code, channel_id, created_at) VALUES (?, ?, ?, ?, ?, datetime('now'))", 
               [author_id, vrc_user['id'], vrc_user['displayName'], code, channel_id])

    dm_channel = create_dm_channel(author_id) || channel_id

    embed = {
      title: "🔗 VRChat Status Link Request (DM)",
      description: "<@#{author_id}>, link request set up for **#{vrc_user['displayName']}** (`#{vrc_user['id']}`).",
      color: 0x3498DB,
      fields: [
        { name: "1. Update Status", value: "Put this exact code into your VRChat status or status description: `#{code}`", inline: false },
        { name: "2. Verify", value: "Once saved, reply here or in server with: `@Manta verify` (expires in 5 minutes)", inline: false }
      ]
    }
    send_fluxer_embed(dm_channel, embed)
    log_event("Link initiated for Fluxer ID #{author_id} -> VRChat #{vrc_user['displayName']}")

    if dm_channel != channel_id
      send_fluxer_embed(channel_id, {
        title: "📨 Check Your DMs!",
        description: "<@#{author_id}> I have sent you a Direct Message with your verification code and instructions.",
        color: 0x2ECC71
      })
    end

  when 'verify'
    pending = DB.get_first_row("SELECT * FROM pending WHERE fluxer_id = ?", [author_id])
    unless pending
      embed = {
        title: "❌ No Pending Link",
        description: "<@#{author_id}> You don't have a pending link request. Use `@Manta link <name or profile url>` first.",
        color: 0xE74C3C
      }
      return send_fluxer_embed(channel_id, embed)
    end

    _, vrchat_id, vrchat_username, code, original_channel_id = pending
    
    vrc_user = fetch_vrchat_user_by_id(vrchat_id)
    unless vrc_user
      embed = {
        title: "❌ API Error",
        description: "<@#{author_id}> Failed to fetch VRChat profile details.",
        color: 0xE74C3C
      }
      return send_fluxer_embed(channel_id, embed)
    end

    status_desc = vrc_user['statusDescription'].to_s
    status = vrc_user['status'].to_s

    if status_desc.include?(code) || status.include?(code)
      DB.execute("INSERT OR REPLACE INTO verified (fluxer_id, vrchat_id, vrchat_username) VALUES (?, ?, ?)", [author_id, vrc_user['id'], vrc_user['displayName']])
      DB.execute("DELETE FROM pending WHERE fluxer_id = ?", [author_id])
      
      tags = vrc_user['tags'] || []
      is_18_plus = tags.include?('system_18_plus')

      if guild_id
        settings = DB.get_first_row("SELECT verified_role_id, adult_role_id FROM settings WHERE guild_id = ?", [guild_id])
        if settings
          ver_role, adult_role = settings
          assign_fluxer_role(guild_id, author_id, ver_role) if ver_role
          assign_fluxer_role(guild_id, author_id, adult_role) if is_18_plus && adult_role
        end
      end

      embed = {
        title: "✅ Account Successfully Linked!",
        description: "<@#{author_id}> is now successfully linked to VRChat user **#{vrc_user['displayName']}**!#{is_18_plus ? ' (18+ Age-Gate Verified)' : ''}",
        color: 0x2ECC71
      }
      send_fluxer_embed(channel_id, embed)
      log_event("Successfully verified and linked Fluxer ID #{author_id} to VRChat #{vrc_user['displayName']}")
    else
      embed = {
        title: "❌ Verification Failed",
        description: "<@#{author_id}> Couldn't find code `#{code}` in your VRChat status or status description. Make sure you saved your profile changes!",
        color: 0xE74C3C
      }
      send_fluxer_embed(channel_id, embed)
      log_event("Verification failed for Fluxer ID #{author_id} (code not found in status)")
    end

  when 'unlink'
    row = DB.get_first_row("SELECT vrchat_id, vrchat_username FROM verified WHERE fluxer_id = ?", [author_id])
    unless row
      embed = {
        title: "❌ No Linked Account",
        description: "<@#{author_id}> You do not have a linked VRChat account to unlink.",
        color: 0xE74C3C
      }
      return send_fluxer_embed(channel_id, embed)
    end

    vrc_id, vrc_name = row
    DB.execute("DELETE FROM verified WHERE fluxer_id = ?", [author_id])
    
    # Set 2-hour cooldown for both Fluxer ID and VRChat ID
    DB.execute("INSERT OR REPLACE INTO cooldowns (identifier, expires_at) VALUES (?, datetime('now', '+2 hours'))", [author_id])
    DB.execute("INSERT OR REPLACE INTO cooldowns (identifier, expires_at) VALUES (?, datetime('now', '+2 hours'))", [vrc_id])

    embed = {
      title: "🔓 Account Unlinked",
      description: "<@#{author_id}> Successfully unlinked VRChat account **#{vrc_name}**. \n⚠️ *Note: To prevent abuse, both accounts are temporarily blocked from re-linking for **2 hours**.*",
      color: 0xE67E22
    }
    send_fluxer_embed(channel_id, embed)
    log_event("User #{author_id} unlinked VRChat account #{vrc_name} (2-hour cooldown applied)")

  when 'profile'
    row = DB.get_first_row("SELECT * FROM verified WHERE fluxer_id = ?", [author_id])
    if row
      _, vrchat_id, vrchat_username = row
      embed = {
        title: "👤 Linked VRChat Profile",
        description: "<@#{author_id}>'s linked VRChat account:",
        color: 0x3498DB,
        fields: [
          { name: "Display Name", value: vrchat_username, inline: true },
          { name: "VRChat ID", value: "`#{vrchat_id}`", inline: true }
        ]
      }
      send_fluxer_embed(channel_id, embed)
    else
      embed = {
        title: "👤 No Linked Account",
        description: "<@#{author_id}> You don't have a linked VRChat account. Use `@Manta link <name or profile url>` to start.",
        color: 0x95A5A6
      }
      send_fluxer_embed(channel_id, embed)
    end

  when 'whois'
    target_input = args[1..-1]&.join(' ')
    row = nil

    if target_input.nil? || target_input.empty?
      row = DB.get_first_row("SELECT * FROM verified WHERE fluxer_id = ?", [author_id])
      unless row
        embed = {
          title: "❌ Link Not Found",
          description: "<@#{author_id}> You don't have a linked VRChat account. Use `@Manta whois <mention, user ID, or VRChat name>` to check someone else.",
          color: 0xE74C3C
        }
        return send_fluxer_embed(channel_id, embed)
      end
    else
      match = target_input.match(/^<@!?(\d+)>$/)
      if match
        target_id = match[1]
        row = DB.get_first_row("SELECT * FROM verified WHERE fluxer_id = ?", [target_id])
      elsif target_input =~ /^\d+$/
        row = DB.get_first_row("SELECT * FROM verified WHERE fluxer_id = ?", [target_input])
      end

      unless row
        row = DB.get_first_row("SELECT * FROM verified WHERE vrchat_username LIKE ?", [target_input])
      end

      unless row
        embed = {
          title: "❌ Link Not Found",
          description: "<@#{author_id}> No linked VRChat account found for `#{target_input}`.",
          color: 0xE74C3C
        }
        return send_fluxer_embed(channel_id, embed)
      end
    end

    _, vrchat_id, vrchat_username, linked_at = row
    vrc_user = fetch_vrchat_user_by_id(vrchat_id)
    
    display_name = vrc_user ? (vrc_user['displayName'] || vrchat_username) : vrchat_username
    tags = vrc_user ? (vrc_user['tags'] || []) : []
    is_18_plus = tags.include?('system_18_plus')
    is_vrc_plus = tags.include?('system_supporter') || tags.include?('vrchat_plus') || tags.any? { |t| t.include?('supporter') }
    profile_url = "https://vrchat.com/home/user/#{vrchat_id}"

    pfp_url = vrc_user && (vrc_user['userIcon'] || vrc_user['profilePicOverride'] || vrc_user['currentAvatarThumbnailImageUrl'])

    raw_status_desc = vrc_user ? vrc_user['statusDescription'] : ''
    status_desc = !raw_status_desc.to_s.strip.empty? ? raw_status_desc : "No status description"
    
    status = vrc_user ? vrc_user['status'].to_s.capitalize : "Unknown"
    state = vrc_user ? vrc_user['state'].to_s.capitalize : "Offline"

    status_desc = status_desc.length > 256 ? status_desc[0..253] + "..." : status_desc

    embed = {
      title: "🔍 VRChat Profile: #{display_name}",
      color: 0x3498DB,
      fields: [
        { name: "Display Name", value: display_name, inline: true },
        { name: "Status", value: "#{status} (#{state})", inline: true },
        { name: "VRChat Plus", value: is_vrc_plus ? "Yes" : "No", inline: true },
        { name: "18+ Account", value: is_18_plus ? "True" : "False", inline: true },
        { name: "User ID", value: "`#{vrchat_id}`", inline: false },
        { name: "Status Description", value: status_desc, inline: false },
        { name: "Profile Link", value: "[View Profile on VRChat](#{profile_url})", inline: false }
      ]
    }

    embed[:thumbnail] = { url: pfp_url } if pfp_url && !pfp_url.empty?

    send_fluxer_embed(channel_id, embed)
  end
end

# --- Start WebSocket Gateway Client ---
log_event("Starting Manta VRChat Bot...")
ws = WebSocket::Client::Simple.connect(GATEWAY_URL)
heartbeat_thread = nil

ws.on :open do
  log_event("Connected to Gateway! Waiting for handshake...")
end

ws.on :message do |msg|
  payload = JSON.parse(msg.data) rescue next
  
  if payload['op'] == 10
    interval = payload['d']['heartbeat_interval'] / 1000.0
    log_event("Received Hello. Heartbeating every #{interval}s...")

    heartbeat_thread&.kill
    heartbeat_thread = Thread.new do
      loop do
        sleep interval
        ws.send({ op: 1, d: nil }.to_json) rescue break
      end
    end

    ws.send({
      op: 2,
      d: {
        token: BOT_TOKEN,
        intents: 33281,
        properties: { os: 'ruby', browser: 'websocket-client-simple', device: 'websocket' },
        presence: {
          status: "online",
          since: nil,
          activities: [],
          afk: false
        }
      }
    }.to_json)
    
    next
  end

  if payload['op'] == 0 && payload['t'] == 'MESSAGE_CREATE'
    message = payload['d']
    next if message['author'] && message['author']['bot']

    bot_mention = "<@#{BOT_ID}>"
    bot_mention_nick = "<@!#{BOT_ID}>"

    content = message['content'].to_s
    if content.start_with?(bot_mention) || content.start_with?(bot_mention_nick)
      mention_used = content.start_with?(bot_mention) ? bot_mention : bot_mention_nick
      raw_args = content[mention_used.length..-1].strip.split(/\s+/)

      unless raw_args.empty?
        begin
          handle_command(message['channel_id'], message['author']['id'], raw_args, message['guild_id'])
        rescue => e
          log_event("CRITICAL ERROR in handle_command: #{e.message}\n#{e.backtrace.join("\n")}")
        end
      end
    end
  end
end

ws.on :close do |e|
  heartbeat_thread&.kill
  log_event("WebSocket closed: #{e.inspect}")
end

ws.on :error do |e|
  heartbeat_thread&.kill
  log_event("WebSocket error: #{e.inspect}")
end

loop do
  sleep 1
end