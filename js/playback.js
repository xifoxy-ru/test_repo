import { phenomena } from './data.js';
export function createPlayer(data = phenomena) {
  let item = null, index = 0, status = 'idle', message = 'Choose a signal to begin.';
  let volume = 0.05, lastVolume = 0.05, muted = false;
  let context = null, oscillator = null, gain = null, timer = null, generation = 0;
  const listeners = new Set();
  const snapshot = () => ({ id: item?.id ?? null, index, value: item?.values[index] ?? null, status, message, volume, muted });
  const emit = () => { const state = snapshot(); listeners.forEach(listener => listener(state)); };
  const silence = () => {
    generation++; clearInterval(timer); timer = null;
    if (oscillator) { try { oscillator.stop(); } catch (_) {} oscillator.disconnect(); oscillator = null; }
    if (gain) { gain.disconnect(); gain = null; }
  };
  const validData = () => Array.isArray(data) && data.length > 0 && data.every(entry =>
    entry && typeof entry.id === 'string' && entry.id.trim() && Array.isArray(entry.values) && entry.values.length > 0 &&
    entry.values.every(value => typeof value === 'number' && Number.isFinite(value) && value >= 0 && value <= 1)) &&
    new Set(data.map(entry => entry.id)).size === data.length;
  const error = text => { silence(); status = 'error'; message = text; emit(); };
  const applyFrame = () => { oscillator.frequency.setValueAtTime(220 + 440 * item.values[index], context.currentTime); emit(); };
  function select(id) {
    silence();
    if (!validData() || typeof id !== 'string' || !(item = data.find(entry => entry.id === id))) {
      item = null; index = 0; error('This signal is unavailable or contains invalid mock data.'); return;
    }
    index = 0; status = 'stopped'; message = 'Ready to play.'; emit();
  }
  async function play() {
    if (!validData() || !item || !data.includes(item)) { error('Choose a valid signal before playing.'); return; }
    if (status === 'playing' || status === 'loading') return;
    silence(); const request = generation;
    status = 'loading'; message = 'Starting audio…'; emit();
    try {
      const Audio = window.AudioContext || window.webkitAudioContext;
      if (!Audio) throw new Error('Web Audio unavailable');
      if (!context || context.state === 'closed') context = new Audio();
      if (context.state !== 'running') await context.resume();
      if (request !== generation) return;
      if (context.state !== 'running') throw new Error('Audio blocked');
      oscillator = context.createOscillator(); gain = context.createGain();
      oscillator.type = 'sine'; gain.gain.setValueAtTime(muted ? 0 : volume, context.currentTime);
      oscillator.connect(gain); gain.connect(context.destination);
      oscillator.frequency.setValueAtTime(220 + 440 * item.values[index], context.currentTime);
      oscillator.start(); status = 'playing'; message = 'Playing mock signal.'; emit();
      timer = setInterval(() => {
        if (index === item.values.length - 1) { stop(); message = 'Signal complete. Ready to play again.'; emit(); return; }
        index++; applyFrame();
      }, 1000);
    } catch (_) { if (request === generation) error('Audio could not start. Check your browser or audio settings, then try Play again.'); }
  }
  function pause() { if (status !== 'playing' && status !== 'loading') return; silence(); status = 'paused'; message = 'Paused. Press Play to resume.'; emit(); }
  function stop() { silence(); index = 0; status = item ? 'stopped' : 'idle'; message = item ? 'Stopped. Back at the first frame.' : 'Choose a signal to begin.'; emit(); }
  function setVolume(value) {
    if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || value > 0.2) { message = 'Volume must be a number between 0 and 0.2.'; emit(); return; }
    volume = value; if (value > 0) lastVolume = value;
    if (gain) gain.gain.setValueAtTime(muted ? 0 : volume, context.currentTime);
    message = muted ? 'Muted.' : 'Volume updated.'; emit();
  }
  function setMuted(value) {
    if (typeof value !== 'boolean') { message = 'Mute must be on or off.'; emit(); return; }
    muted = value; if (!muted) volume = lastVolume || 0.05;
    if (gain) gain.gain.setValueAtTime(muted ? 0 : volume, context.currentTime);
    message = muted ? 'Muted.' : 'Sound on.'; emit();
  }
  function subscribe(listener) { listeners.add(listener); listener(snapshot()); return () => listeners.delete(listener); }
  document.addEventListener('visibilitychange', () => { if (document.hidden) pause(); });
  return { select, play, pause, stop, setVolume, setMuted, subscribe };
}
export const player = createPlayer();
