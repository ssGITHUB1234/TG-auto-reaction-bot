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

/**
 * Helper: convert supabase row (array or single) to plain object
 */
function normalizeRow(res) {
  if (!res) return null;
  // supabase responses: { data, error }
  if (res.data) {
    if (Array.isArray(res.data)) return res.data;
    return res.data;
  }
  return null;
}

// Helper: start a bot and attach handlers
async function startBot(botRow) {
  if (!botRow || !botRow.token) return;
  const botId = botRow.id;
  if (botInstances.has(botId)) return; // already running

  const bot = new Telegraf(botRow.token);

  bot.start(async (ctx) => {
    try {
      const tUser = ctx.from;
      // insert into bot_users (if not exists)
      await supabase
        .from('bot_users')
        .upsert({
          bot_id: botId,
          telegram_id: String(tUser.id),
          username: tUser.username || '',
          first_name: tUser.first_name || '',
          last_name: tUser.last_name || ''
        }, { onConflict: ['bot_id', 'telegram_id'] });

      // optional: send force join message
      if (botRow.force_join_channel) {
        try {
          await ctx.reply(`Please join this channel first: ${botRow.force_join_channel}`);
        } catch (err) { /* ignore reply errors */ }
      }
    } catch (err) {
      console.error('start handler error', err);
    }
  });

  bot.catch((err) => {
    console.error('Bot error', botId, err);
  });

  // launch using long polling
  try {
    await bot.launch();
    botInstances.set(botId, { bot, token: botRow.token });
    console.log('Launched bot', botId);
  } catch (err) {
    console.error('Failed launching bot', botId, err);
  }
}

// stop bot
async function stopBot(botId) {
  const inst = botInstances.get(botId);
  if (!inst) return;
  try {
    await inst.bot.stop();
  } catch (e) { /* ignore */ }
  botInstances.delete(botId);
  console.log('Stopped bot', botId);
}

// On start: load enabled bots
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

// API

// Create a bot (store token, owner, title)
app.post('/api/bots', async (req, res) => {
  const { token, owner, title } = req.body;
  if (!token || !owner) return res.status(400).json({ error: 'token and owner required' });

  const payload = { token, owner, title: title || '', enabled: true };
  const { data, error } = await supabase.from('bots').insert(payload).select().single();
  if (error) return res.status(500).json({ error: error.message });

  // start it
  await startBot(data);
  res.json({ bot: data });
});

// List bots (optionally by owner)
app.get('/api/bots', async (req, res) => {
  const owner = req.query.owner;
  let query = supabase.from('bots').select('*').order('id', { ascending: true });
  if (owner) query = query.eq('owner', owner);
  const { data, error } = await query;
  if (error) return res.status(500).json({ error: error.message });
  res.json({ bots: data });
});

// Toggle bot on/off (owner or admin)
app.post('/api/bots/:id/toggle', async (req, res) => {
  const id = Number(req.params.id);
  const { enable, admin_password, owner } = req.body;
  const { data: botRows, error: getErr } = await supabase.from('bots').select('*').eq('id', id).single();
  if (getErr || !botRows) return res.status(404).json({ error: 'bot not found' });

  const botRow = botRows;

  // authorize: admin or owner
  if (!(admin_password === ADMIN_PASSWORD || owner === botRow.owner)) {
    return res.status(403).json({ error: 'forbidden' });
  }

  const { error } = await supabase.from('bots').update({ enabled: enable ? true : false }).eq('id', id);
  if (error) return res.status(500).json({ error: error.message });

  if (enable) startBot({ ...botRow, enabled: true });
  else stopBot(id);

  res.json({ ok: true });
});

// Broadcast message to all users of a bot
app.post('/api/bots/:id/broadcast', async (req, res) => {
  const id = Number(req.params.id);
  const { message, admin_password, owner } = req.body;
  const { data: botRow, error: getErr } = await supabase.from('bots').select('*').eq('id', id).single();
  if (getErr || !botRow) return res.status(404).json({ error: 'bot not found' });

  // authorize: owner or admin
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
    } catch (err) {
      // ignore per-user send errors
    }
  }

  await supabase.from('broadcasts').insert({ bot_id: id, message });

  res.json({ ok: true, attempted: users.length, sent });
});

// Force-join channel update
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

// Get bot stats (users count)
app.get('/api/bots/:id/stats', async (req, res) => {
  const id = Number(req.params.id);
  const { data: botRow, error: getErr } = await supabase.from('bots').select('*').eq('id', id).single();
  if (getErr || !botRow) return res.status(404).json({ error: 'bot not found' });

  const { data: cnt, error } = await supabase.from('bot_users').select('id', { count: 'exact', head: true }).eq('bot_id', id);
  if (error) return res.status(500).json({ error: error.message });

  const totalUsers = cnt ?? 0;
  res.json({ bot: botRow, stats: { totalUsers } });
});

// Admin login (simple)
app.post('/api/admin/login', (req, res) => {
  const { password } = req.body;
  if (password === ADMIN_PASSWORD) return res.json({ ok: true });
  return res.status(401).json({ error: 'invalid' });
});

// Admin global toggle: control all bots at once
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
  console.log(`Server listening on ${PORT}`);
});

// Graceful shutdown
process.once('SIGINT', () => process.exit(0));
process.once('SIGTERM', () => process.exit(0));
