#!/usr/bin/env bash
set -euo pipefail

echo "Creating files for TG-auto-reaction-bot (Supabase backend)..."

# Ensure running in repo root
if [ ! -d ".git" ]; then
  echo "No .git directory found. Please run this inside your local repo root (or run 'git init' first)."
  exit 1
fi

# Create directories
mkdir -p public migrations

cat > README.md <<'EOF'
# TG-auto-reaction-bot (Supabase backend)

This project manages multiple Telegram reaction/broadcast bots using Supabase (Postgres) as the backend.

Quick overview
- Use Supabase to store bots, bot users, and broadcasts.
- Admin and user dashboards remain as static pages.
- ADMIN_PASSWORD still used for simple admin authentication.
- Long-polling Telegraf bots are launched inside the server process.

Setup (Supabase)
1. Create a Supabase project at https://app.supabase.com/.
2. Go to the SQL Editor and run the SQL in `migrations/init.sql` to create the tables.
3. In Project Settings → API, copy:
   - SUPABASE_URL (the project URL)
   - SUPABASE_KEY (service_role key or anon key — for server usage use service_role if needed; store it securely)
4. Set environment variables:
   - SUPABASE_URL
   - SUPABASE_KEY
   - ADMIN_PASSWORD
   - PORT (optional)

Local run
1. Copy `.env.example` to `.env` and fill values.
2. npm install
3. npm start
4. Visit:
   - http://localhost:3000/index.html (user)
   - http://localhost:3000/admin.html (admin)

Render deployment
- Add SUPABASE_URL and SUPABASE_KEY as environment variables in Render.
- Add ADMIN_PASSWORD env var.
- Build command: `npm install`
- Start command: `node server.js`

Important notes & security
- Use the Supabase service_role key only on server-side and keep it secret. Do NOT put it in client-side code.
- Consider enabling Row Level Security and policies in Supabase if you later expose APIs that might be called by clients directly.
- For production, avoid storing bot tokens in plaintext if possible — consider encryption or a secrets manager.
EOF

cat > .env.example <<'EOF'
PORT=3000
ADMIN_PASSWORD=change_me_to_a_strong_password

# Supabase (required)
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_KEY=your-supabase-service-role-or-anon-key
EOF

cat > package.json <<'EOF'
{
  "name": "tg-auto-reaction-bot",
  "version": "0.1.1",
  "description": "Manage multiple Telegram reaction/broadcast bots with Supabase backend",
  "main": "server.js",
  "scripts": {
    "start": "node server.js",
    "dev": "NODE_ENV=development nodemon server.js"
  },
  "engines": {
    "node": ">=16"
  },
  "dependencies": {
    "@supabase/supabase-js": "^2.28.0",
    "express": "^4.18.2",
    "telegraf": "^4.13.0",
    "body-parser": "^1.20.2",
    "cors": "^2.8.5",
    "dotenv": "^16.3.1"
  },
  "devDependencies": {
    "nodemon": "^3.0.2"
  }
}
EOF

cat > supabase.js <<'EOF'
const { createClient } = require('@supabase/supabase-js');

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_KEY = process.env.SUPABASE_KEY;

if (!SUPABASE_URL || !SUPABASE_KEY) {
  console.error('Missing SUPABASE_URL or SUPABASE_KEY in environment');
  process.exit(1);
}

const supabase = createClient(SUPABASE_URL, SUPABASE_KEY);

module.exports = { supabase };
EOF

cat > server.js <<'EOF'
require('dotenv').config();
const express = require('express');
const bodyParser = require('body-parser');
const cors = require('cors');
const { Telegraf } = require('telegraf');
const { supabase } = require('./supabase');

const app = express();
app.use(cors());
app.use(bodyParser.json());
app.use(express.static('public'));

const PORT = process.env.PORT || 3000;
const ADMIN_PASSWORD = process.env.ADMIN_PASSWORD || 'change_me';

const botInstances = new Map(); // botId -> { bot, token }

// Helper: start a bot and attach handlers
async function startBot(botRow) {
  if (!botRow || !botRow.token) return;
  const botId = botRow.id;
  if (botInstances.has(botId)) return;

  const bot = new Telegraf(botRow.token);

  bot.start(async (ctx) => {
    try {
      const tUser = ctx.from;
      await supabase
        .from('bot_users')
        .upsert({
          bot_id: botId,
          telegram_id: String(tUser.id),
          username: tUser.username || '',
          first_name: tUser.first_name || '',
          last_name: tUser.last_name || ''
        }, { onConflict: ['bot_id', 'telegram_id'] });

      if (botRow.force_join_channel) {
        try {
          await ctx.reply(\`Please join this channel first: \${botRow.force_join_channel}\`);
        } catch (err) {}
      }
    } catch (err) {
      console.error('start handler error', err);
    }
  });

  bot.catch((err) => {
    console.error('Bot error', botId, err);
  });

  try {
    await bot.launch();
    botInstances.set(botId, { bot, token: botRow.token });
    console.log('Launched bot', botId);
  } catch (err) {
    console.error('Failed launching bot', botId, err);
  }
}

async function stopBot(botId) {
  const inst = botInstances.get(botId);
  if (!inst) return;
  try {
    await inst.bot.stop();
  } catch (e) {}
  botInstances.delete(botId);
  console.log('Stopped bot', botId);
}

async function loadAndStartEnabledBots() {
  const { data, error } = await supabase.from('bots').select('*').eq('enabled', true);
  if (error) {
    console.error('Error loading enabled bots', error);
    return;
  }
  for (const b of data) {
    startBot(b);
  }
}
loadAndStartEnabledBots();

// API endpoints

app.post('/api/bots', async (req, res) => {
  const { token, owner, title } = req.body;
  if (!token || !owner) return res.status(400).json({ error: 'token and owner required' });

  const payload = { token, owner, title: title || '', enabled: true };
  const { data, error } = await supabase.from('bots').insert(payload).select().single();
  if (error) return res.status(500).json({ error: error.message });

  await startBot(data);
  res.json({ bot: data });
});

app.get('/api/bots', async (req, res) => {
  const owner = req.query.owner;
  let query = supabase.from('bots').select('*').order('id', { ascending: true });
  if (owner) query = query.eq('owner', owner);
  const { data, error } = await query;
  if (error) return res.status(500).json({ error: error.message });
  res.json({ bots: data });
});

app.post('/api/bots/:id/toggle', async (req, res) => {
  const id = Number(req.params.id);
  const { enable, admin_password, owner } = req.body;
  const { data: botRow, error: getErr } = await supabase.from('bots').select('*').eq('id', id).single();
  if (getErr || !botRow) return res.status(404).json({ error: 'bot not found' });

  if (!(admin_password === ADMIN_PASSWORD || owner === botRow.owner)) {
    return res.status(403).json({ error: 'forbidden' });
  }

  const { error } = await supabase.from('bots').update({ enabled: enable ? true : false }).eq('id', id);
  if (error) return res.status(500).json({ error: error.message });

  if (enable) startBot({ ...botRow, enabled: true });
  else stopBot(id);

  res.json({ ok: true });
});

app.post('/api/bots/:id/broadcast', async (req, res) => {
  const id = Number(req.params.id);
  const { message, admin_password, owner } = req.body;
  const { data: botRow, error: getErr } = await supabase.from('bots').select('*').eq('id', id).single();
  if (getErr || !botRow) return res.status(404).json({ error: 'bot not found' });

  if (!(admin_password === ADMIN_PASSWORD || owner === botRow.owner)) {
    return res.status(403).json({ error: 'forbidden' });
  }

  const inst = botInstances.get(id);
  if (!inst) return res.status(400).json({ error: 'bot is not running' });

  const { data: users, error: uerr } = await supabase.from('bot_users').select('telegram_id').eq('bot_id', id);
  if (uerr) return res.status(500).json({ error: uerr.message });

  let sent = 0;
  for (const u of users) {
    try {
      await inst.bot.telegram.sendMessage(Number(u.telegram_id), message);
      sent++;
    } catch (err) {}
  }

  await supabase.from('broadcasts').insert({ bot_id: id, message });

  res.json({ ok: true, attempted: users.length, sent });
});

app.post('/api/bots/:id/force_join', async (req, res) => {
  const id = Number(req.params.id);
  const { channel, admin_password, owner } = req.body;
  const { data: botRow, error: getErr } = await supabase.from('bots').select('*').eq('id', id).single();
  if (getErr || !botRow) return res.status(404).json({ error: 'bot not found' });
  if (!(admin_password === ADMIN_PASSWORD || owner === botRow.owner)) {
    return res.status(403).json({ error: 'forbidden' });
  }
  const { error } = await supabase.from('bots').update({ force_join_channel: channel }).eq('id', id);
  if (error) return res.status(500).json({ error: error.message });
  res.json({ ok: true });
});

app.get('/api/bots/:id/stats', async (req, res) => {
  const id = Number(req.params.id);
  const { data: botRow, error: getErr } = await supabase.from('bots').select('*').eq('id', id).single();
  if (getErr || !botRow) return res.status(404).json({ error: 'bot not found' });

  const { count, error } = await supabase.from('bot_users').select('id', { count: 'exact', head: true }).eq('bot_id', id);
  if (error) return res.status(500).json({ error: error.message });

  const totalUsers = count ?? 0;
  res.json({ bot: botRow, stats: { totalUsers } });
});

app.post('/api/admin/login', (req, res) => {
  const { password } = req.body;
  if (password === ADMIN_PASSWORD) return res.json({ ok: true });
  return res.status(401).json({ error: 'invalid' });
});

app.post('/api/admin/toggle_all', async (req, res) => {
  const { enable, admin_password } = req.body;
  if (admin_password !== ADMIN_PASSWORD) return res.status(403).json({ error: 'forbidden' });
  const { data: bots, error } = await supabase.from('bots').select('*');
  if (error) return res.status(500).json({ error: error.message });

  for (const b of bots) {
    await supabase.from('bots').update({ enabled: enable ? true : false }).eq('id', b.id);
    if (enable) startBot(b);
    else stopBot(b.id);
  }
  res.json({ ok: true, count: (bots || []).length });
});

app.listen(PORT, () => {
  console.log(\`Server listening on \${PORT}\`);
});

process.once('SIGINT', () => process.exit(0));
process.once('SIGTERM', () => process.exit(0));
EOF

cat > migrations/init.sql <<'EOF'
-- Run this SQL in Supabase SQL Editor to create tables for TG-auto-reaction-bot

create table if not exists bots (
  id serial primary key,
  token text not null,
  owner text not null,
  title text,
  enabled boolean default true,
  force_join_channel text,
  notify_new_user boolean default false,
  created_at timestamptz default now()
);

create table if not exists bot_users (
  id serial primary key,
  bot_id integer not null references bots (id) on delete cascade,
  telegram_id text not null,
  username text,
  first_name text,
  last_name text,
  started_at timestamptz default now(),
  unique(bot_id, telegram_id)
);

create table if not exists broadcasts (
  id serial primary key,
  bot_id integer not null references bots (id) on delete cascade,
  message text,
  created_at timestamptz default now()
);

create index if not exists idx_bot_users_botid on bot_users (bot_id);
create index if not exists idx_broadcasts_botid on broadcasts (bot_id);
EOF

cat > public/index.html <<'EOF'
<!doctype html>
<html>
<head><meta charset="utf-8"><title>User Dashboard - TG-react</title></head>
<body>
  <h1>User Dashboard</h1>
  <div>
    <label>Your username: <input id="owner" value="" /></label>
    <button id="fetch">Fetch my bots</button>
  </div>
  <div id="bots"></div>

  <script>
    async function fetchBots(owner){
      const r = await fetch('/api/bots?owner=' + encodeURIComponent(owner));
      const j = await r.json();
      return j.bots;
    }
    document.getElementById('fetch').addEventListener('click', async ()=>{
      const owner = document.getElementById('owner').value.trim();
      if(!owner) return alert('Enter your owner name (username)');
      const bots = await fetchBots(owner);
      const container = document.getElementById('bots');
      container.innerHTML = '';
      bots.forEach(b=>{
        const div = document.createElement('div');
        div.innerHTML = `<h3>${b.title || 'untitled'} (id:${b.id})</h3>
          <p>enabled: ${b.enabled}</p>
          <p>force join: ${b.force_join_channel || '-'}</p>
          <button data-id="${b.id}" class="toggle">${b.enabled ? 'Turn off' : 'Turn on'}</button>
          <button data-id="${b.id}" class="stats">Stats</button>
          <button data-id="${b.id}" class="broadcast">Broadcast</button>
        `;
        container.appendChild(div);
      });
    });

    document.getElementById('bots').addEventListener('click', async (e)=>{
      const id = e.target.dataset.id;
      if(!id) return;
      if(e.target.classList.contains('toggle')){
        const owner = document.getElementById('owner').value.trim();
        const enable = e.target.textContent.includes('Turn on');
        await fetch('/api/bots/' + id + '/toggle', {
          method: 'POST',
          headers: {'Content-Type':'application/json'},
          body: JSON.stringify({ owner, enable })
        });
        alert('Toggled. Refreshing...');
        document.getElementById('fetch').click();
      } else if(e.target.classList.contains('stats')){
        const r = await fetch('/api/bots/' + id + '/stats');
        const j = await r.json();
        alert('Total users: ' + j.stats.totalUsers);
      } else if(e.target.classList.contains('broadcast')){
        const msg = prompt('Message to broadcast:');
        if(!msg) return;
        const owner = document.getElementById('owner').value.trim();
        const r = await fetch('/api/bots/' + id + '/broadcast', {
          method:'POST', headers:{'Content-Type':'application/json'},
          body: JSON.stringify({ message: msg, owner })
        });
        const j = await r.json();
        if (j.ok) alert('Broadcast sent to ' + j.sent + '/' + j.attempted);
        else alert('Error: ' + JSON.stringify(j));
      }
    });
  </script>
</body>
</html>
EOF

cat > public/admin.html <<'EOF'
<!doctype html>
<html>
<head><meta charset="utf-8"><title>Admin Dashboard</title></head>
<body>
  <h1>Admin Dashboard</h1>
  <div>
    <label>Password: <input type="password" id="pw" /></label>
    <button id="login">Login</button>
  </div>
  <div id="main" style="display:none;">
    <button id="fetchAll">Fetch all bots</button>
    <button id="toggleAllOn">Enable all</button>
    <button id="toggleAllOff">Disable all</button>
    <div id="list"></div>
  </div>

  <script>
    let adminPw = null;
    document.getElementById('login').addEventListener('click', async ()=>{
      adminPw = document.getElementById('pw').value;
      const r = await fetch('/api/admin/login', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({password: adminPw})});
      if (r.ok) {
        alert('Logged in');
        document.getElementById('main').style.display = '';
      } else {
        alert('Bad password');
      }
    });

    async function fetchAll(){
      const r = await fetch('/api/bots');
      const j = await r.json();
      const list = document.getElementById('list');
      list.innerHTML = '';
      j.bots.forEach(b=>{
        const d = document.createElement('div');
        d.innerHTML = `<h4>${b.title||'untitled'} (id:${b.id}) owner:${b.owner}</h4>
          <p>enabled:${b.enabled} users: -</p>
          <button data-id="${b.id}" class="toggle">${b.enabled ? 'Disable' : 'Enable'}</button>
          <button data-id="${b.id}" class="broadcast">Broadcast</button>
          <button data-id="${b.id}" class="force">Set force-join</button>
        `;
        list.appendChild(d);
      });
    }

    document.getElementById('fetchAll').addEventListener('click', fetchAll);
    document.getElementById('toggleAllOn').addEventListener('click', async ()=>{
      await fetch('/api/admin/toggle_all', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({enable:true, admin_password: adminPw})});
      alert('Enabled all');
      fetchAll();
    });
    document.getElementById('toggleAllOff').addEventListener('click', async ()=>{
      await fetch('/api/admin/toggle_all', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({enable:false, admin_password: adminPw})});
      alert('Disabled all');
      fetchAll();
    });

    document.getElementById('list').addEventListener('click', async (e)=>{
      const id = e.target.dataset.id;
      if(!id) return;
      if(e.target.classList.contains('toggle')){
        const enable = e.target.textContent.includes('Enable');
        await fetch('/api/bots/' + id + '/toggle', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({enable, admin_password: adminPw})});
        fetchAll();
      } else if(e.target.classList.contains('broadcast')){
        const msg = prompt('Message to send:');
        if(!msg) return;
        await fetch('/api/bots/' + id + '/broadcast', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({message: msg, admin_password: adminPw})});
        alert('Broadcast attempt complete');
      } else if(e.target.classList.contains('force')){
        const channel = prompt('Channel invite or username (e.g. @mychannel):');
        if(channel === null) return;
        await fetch('/api/bots/' + id + '/force_join', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({channel, admin_password: adminPw})});
        alert('Updated force-join');
        fetchAll();
      }
    });
  </script>
</body>
</html>
EOF

cat > Dockerfile <<'EOF'
FROM node:18-slim

WORKDIR /app
COPY package.json package-lock.json* ./
RUN npm ci --only=production

COPY . .

ENV PORT=3000
EXPOSE 3000
CMD ["node", "server.js"]
EOF

cat > render.yaml <<'EOF'
services:
  - type: web
    name: tg-auto-reaction-bot
    env: node
    envVars:
      - key: ADMIN_PASSWORD
        scope: all
      - key: NODE_ENV
        value: production
    plan: free
    buildCommand: npm install
    startCommand: node server.js
    instances: 1
EOF

cat > .gitignore <<'EOF'
node_modules/
.env
.env.local
.DS_Store
EOF

echo "Files created. Performing git add, commit, and push to origin main..."

git add .
git commit -m "Add Supabase-backed multi-bot manager"
git push origin main

echo "Done. If git push asked for credentials, provide them (or ensure SSH key is set)."
echo "Next: create a Supabase project, run migrations/init.sql, set SUPABASE_URL and SUPABASE_KEY, then run 'npm install' and 'npm start'."