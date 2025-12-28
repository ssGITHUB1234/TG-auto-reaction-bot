// Updated server.js (Supabase-backed) with reaction behavior, notifications, and extra endpoints
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
 * Start a bot instance with handlers.
 * - Adds /start handler (records users).
 * - Adds message handler to "react" (reply with emoji) when reaction_enabled.
 */
async function startBot(botRow) {
  if (!botRow || !botRow.token) return;
  const botId = botRow.id;
  if (botInstances.has(botId)) return; // already running

  const bot = new Telegraf(botRow.token);

  // When a user starts the bot (sends /start)
  bot.start(async (ctx) => {
    try {
      const tUser = ctx.from;
      // Insert user (or ignore if exists)
      await supabase
        .from('bot_users')
        .upsert({
          bot_id: botId,
          telegram_id: String(tUser.id),
          username: tUser.username || '',
          first_name: tUser.first_name || '',
          last_name: tUser.last_name || ''
        }, { onConflict: ['bot_id', 'telegram_id'] });

      // If notify_new_user is enabled for this bot, create a notification record
      if (botRow.notify_new_user) {
        await supabase.from('notifications').insert({
          bot_id: botId,
          telegram_id: String(tUser.id),
          username: tUser.username || ''
        });
      }

      // If force join is configured, remind the user
      if (botRow.force_join_channel) {
        try {
          await ctx.reply(`Please join this channel first: ${botRow.force_join_channel}`);
        } catch (err) {}
      }
    } catch (err) {
      console.error('start handler error', err);
    }
  });

  // Message handler -> reply with reaction emoji (acts like reaction)
  bot.on('message', async (ctx) => {
    try {
      // reload bot settings from db in case owner updated them
      const { data: fresh, error } = await supabase.from('bots').select('*').eq('id', botId).single();
      if (error || !fresh) return;
      if (fresh.reaction_enabled) {
        const emoji = fresh.reaction_emoji || '❤️';
        try {
          // Reply to the received message with the emoji
          await ctx.reply(emoji, { reply_to_message_id: ctx.message.message_id });
        } catch (err) {
          // ignore per-message errors
        }
      }
    } catch (err) {
      // safe ignore
      console.error('message handler error', err);
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

async function stopBot(botId) {
  const inst = botInstances.get(botId);
  if (!inst) return;
  try {
    await inst.bot.stop();
  } catch (e) {}
  botInstances.delete(botId);
  console.log('Stopped bot', botId);
}

// bootstrap enabled bots at startup
async function loadAndStartEnabledBots() {
  const { data, error } = await supabase.from('bots').select('*').eq('enabled', true);
  if (error) {
    console.error('Error loading enabled bots', error);
    return;
  }
  for (const b of data) startBot(b);
}
loadAndStartEnabledBots();

/* ---------- API ---------- */

// Create bot (user pastes token) — immediate start
app.post('/api/bots', async (req, res) => {
  const { token, owner, title, force_join_channel, notify_new_user, reaction_enabled, reaction_emoji } = req.body;
  if (!token || !owner) return res.status(400).json({ error: 'token and owner required' });

  const payload = {
    token,
    owner,
    title: title || '',
    force_join_channel: force_join_channel || null,
    notify_new_user: !!notify_new_user,
    reaction_enabled: reaction_enabled === undefined ? true : !!reaction_enabled,
    reaction_emoji: reaction_emoji || '❤️',
    enabled: true
  };

  const { data, error } = await supabase.from('bots').insert(payload).select().single();
  if (error) return res.status(500).json({ error: error.message });

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

// Update general settings for a bot (owner or admin)
app.post('/api/bots/:id/settings', async (req, res) => {
  const id = Number(req.params.id);
  const { admin_password, owner, payload } = req.body; // payload: object with fields to update
  if (!payload || typeof payload !== 'object') return res.status(400).json({ error: 'payload required' });

  const { data: botRow, error: getErr } = await supabase.from('bots').select('*').eq('id', id).single();
  if (getErr || !botRow) return res.status(404).json({ error: 'bot not found' });

  if (!(admin_password === ADMIN_PASSWORD || owner === botRow.owner)) return res.status(403).json({ error: 'forbidden' });

  const { error } = await supabase.from('bots').update(payload).eq('id', id);
  if (error) return res.status(500).json({ error: error.message });

  res.json({ ok: true });
});

// Toggle bot on/off
app.post('/api/bots/:id/toggle', async (req, res) => {
  const id = Number(req.params.id);
  const { enable, admin_password, owner } = req.body;
  const { data: botRow, error: getErr } = await supabase.from('bots').select('*').eq('id', id).single();
  if (getErr || !botRow) return res.status(404).json({ error: 'bot not found' });
  if (!(admin_password === ADMIN_PASSWORD || owner === botRow.owner)) return res.status(403).json({ error: 'forbidden' });

  const { error } = await supabase.from('bots').update({ enabled: enable ? true : false }).eq('id', id);
  if (error) return res.status(500).json({ error: error.message });

  if (enable) startBot({ ...botRow, enabled: true });
  else stopBot(id);

  res.json({ ok: true });
});

// Broadcast to bot users
app.post('/api/bots/:id/broadcast', async (req, res) => {
  const id = Number(req.params.id);
  const { message, admin_password, owner } = req.body;
  if (!message) return res.status(400).json({ error: 'message required' });
  const { data: botRow, error: getErr } = await supabase.from('bots').select('*').eq('id', id).single();
  if (getErr || !botRow) return res.status(404).json({ error: 'bot not found' });
  if (!(admin_password === ADMIN_PASSWORD || owner === botRow.owner)) return res.status(403).json({ error: 'forbidden' });

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

// Get per-bot stats (total users)
app.get('/api/bots/:id/stats', async (req, res) => {
  const id = Number(req.params.id);
  const { data: botRow, error: getErr } = await supabase.from('bots').select('*').eq('id', id).single();
  if (getErr || !botRow) return res.status(404).json({ error: 'bot not found' });

  const { count, error } = await supabase.from('bot_users').select('id', { count: 'exact', head: true }).eq('bot_id', id);
  if (error) return res.status(500).json({ error: error.message });

  const totalUsers = count ?? 0;
  res.json({ bot: botRow, stats: { totalUsers } });
});

// Simple admin login
app.post('/api/admin/login', (req, res) => {
  const { password } = req.body;
  if (password === ADMIN_PASSWORD) return res.json({ ok: true });
  return res.status(401).json({ error: 'invalid' });
});

// Admin: toggle all bots
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

// Admin: fetch notifications (new user starts)
app.get('/api/admin/notifications', async (req, res) => {
  const { admin_password } = req.query;
  if (admin_password !== ADMIN_PASSWORD) return res.status(403).json({ error: 'forbidden' });
  const { data, error } = await supabase.from('notifications').select('*').order('created_at', { ascending: false }).limit(100);
  if (error) return res.status(500).json({ error: error.message });
  res.json({ notifications: data });
});

// Stats endpoint: total bots and per-user counts
app.get('/api/stats', async (req, res) => {
  try {
    const { data: totalResp, error: totalErr } = await supabase.from('bots').select('id', { head: true, count: 'exact' });
    if (totalErr) return res.status(500).json({ error: totalErr.message });
    const totalBots = totalResp ?? 0;

    // simple per-user counts
    const { data: rows, error: groupErr } = await supabase
      .from('bots')
      .select('owner, id')
      .order('owner', { ascending: true });

    if (groupErr) return res.status(500).json({ error: groupErr.message });

    const counts = {};
    for (const r of rows) counts[r.owner] = (counts[r.owner] || 0) + 1;

    res.json({ totalBots, perUserCounts: counts });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

app.listen(PORT, () => {
  console.log(`Server listening on ${PORT}`);
});

process.once('SIGINT', () => process.exit(0));
process.once('SIGTERM', () => process.exit(0));
