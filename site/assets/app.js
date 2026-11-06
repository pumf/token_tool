/* TokenTool 宣传站交互：进场动画、菜单栏滚动仿真、粒子背景、主题与下载引导 */
(() => {
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ---------------- 主题 ---------------- */
  const themeToggle = document.getElementById('themeToggle');
  const savedTheme = localStorage.getItem('tokentool-theme');
  if (savedTheme) document.documentElement.dataset.theme = savedTheme;
  themeToggle?.addEventListener('click', () => {
    const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
    document.documentElement.dataset.theme = next;
    localStorage.setItem('tokentool-theme', next);
  });

  /* ---------------- 滚动进度 ---------------- */
  const progress = document.getElementById('scrollProgress');
  const updateProgress = () => {
    const max = document.documentElement.scrollHeight - window.innerHeight;
    if (progress) progress.style.transform = `scaleX(${max > 0 ? window.scrollY / max : 0})`;
  };
  document.addEventListener('scroll', updateProgress, { passive: true });
  updateProgress();

  /* ---------------- 进场揭示 + 数字计数 ---------------- */
  const counters = new WeakSet();
  const runCounter = (el) => {
    if (counters.has(el)) return;
    counters.add(el);
    const target = Number(el.dataset.count || 0);
    if (reduced) { el.textContent = String(target); return; }
    const startedAt = performance.now();
    const step = (now) => {
      const t = Math.min(1, (now - startedAt) / 1100);
      el.textContent = String(Math.round(target * (1 - Math.pow(1 - t, 3))));
      if (t < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  };

  const observer = new IntersectionObserver((entries) => {
    for (const entry of entries) {
      if (!entry.isIntersecting) continue;
      entry.target.classList.add('in-view');
      entry.target.querySelectorAll('[data-count]').forEach(runCounter);
      observer.unobserve(entry.target);
    }
  }, { rootMargin: '0px 0px -12% 0px', threshold: 0.12 });

  document.querySelectorAll('.reveal, .forecast-viz, .popover-demo').forEach((el) => observer.observe(el));

  /* ---------------- 菜单栏滚动仿真（两拍逐像素等宽） ---------------- */
  const roll = document.getElementById('mbRoll');
  const beats = {
    remaining: [['Q', '2,665'], ['W', '1,270'], ['C', '46%']],
    today: [['Q', '↓22'], ['W', '↓24'], ['C', '46%']],
  };

  // 与真实实现同构：每个平台占两拍里较宽的一拍，零头用空格补在两端，切拍整行宽度不变。
  const slotOf = (index) => Math.max(
    (beats.remaining[index][0] + ' ' + beats.remaining[index][1]).length,
    (beats.today[index][0] + ' ' + beats.today[index][1]).length,
  );

  const renderBeat = (which) => beats[which].map((part, index) => {
    const text = `${part[0]} ${part[1]}`;
    const slot = slotOf(index);
    const fill = slot - text.length;
    const head = Math.floor(fill / 2);
    const padded = `${part[0]} ${' '.repeat(head)}${part[1]}${' '.repeat(fill - head)}`;
    return `<span class="mb-item">${padded.replace(/ /g, '&nbsp;')}</span>`;
  }).join('<span class="mb-sep">···</span>');

  if (roll) {
    let showsToday = false;
    roll.innerHTML = renderBeat('remaining');
    if (!reduced) {
      setInterval(() => {
        roll.classList.add('flip');
        setTimeout(() => {
          showsToday = !showsToday;
          roll.innerHTML = renderBeat(showsToday ? 'today' : 'remaining');
          roll.classList.remove('flip');
        }, 280);
      }, 5000);
    }
  }

  /* ---------------- 提醒三态轮播 ---------------- */
  const alertBar = document.getElementById('alertBar');
  if (alertBar) {
    const states = ['normal', 'warn', 'claim'];
    let cursor = 0;
    const apply = () => {
      const state = states[cursor % states.length];
      alertBar.dataset.state = state;
      alertBar.querySelectorAll('.ab-state').forEach((el) => {
        el.classList.toggle('on', el.dataset.state === state);
      });
      cursor += 1;
    };
    apply();
    if (!reduced) setInterval(apply, 3400);
  }

  /* ---------------- 截图切换 ---------------- */
  const shots = {
    detailed: ['panel-detailed-light.png', 'panel-detailed-dark.png'],
    simple: ['panel-simple-light.png', 'panel-simple-dark.png'],
    settings: ['panel-settings-light.png', 'panel-settings-dark.png'],
  };
  const shotLight = document.getElementById('shotLight');
  const shotDark = document.getElementById('shotDark');
  document.querySelectorAll('.shot-tabs button').forEach((button) => {
    button.addEventListener('click', () => {
      document.querySelectorAll('.shot-tabs button').forEach((other) => {
        other.setAttribute('aria-selected', String(other === button));
      });
      const pair = shots[button.dataset.shot];
      if (!pair) return;
      [shotLight, shotDark].forEach((img, index) => {
        if (!img) return;
        img.style.opacity = '0';
        img.style.transform = 'translateY(10px)';
        img.onload = () => { img.style.opacity = '1'; img.style.transform = 'none'; };
        img.style.transition = 'opacity .35s cubic-bezier(.22,.61,.36,1), transform .35s cubic-bezier(.22,.61,.36,1)';
        img.src = `assets/screens/${pair[index]}`;
      });
    });
  });

  /* ---------------- 芯片匹配下载 ---------------- */
  const heroDownload = document.getElementById('heroDownload');
  const armHint = document.getElementById('dlArmHint');
  const armCard = document.getElementById('dlArm');
  const intelHref = 'https://github.com/pumf/token_tool/releases/download/v1.6.5/TokenTool-1.6.5-x86_64.dmg';
  const armHref = 'https://github.com/pumf/token_tool/releases/download/v1.6.5/TokenTool-1.6.5-arm64.dmg';
  const markIntel = () => {
    if (heroDownload) { heroDownload.href = intelHref; heroDownload.textContent = '下载 Intel 版'; }
    if (armHint) armHint.textContent = 'Intel 机型请看上一行';
  };
  const markArm = () => {
    armCard?.classList.add('match');
    if (armHint) armHint.textContent = '已匹配你的芯片 · Apple Silicon';
  };
  if (navigator.userAgentData?.getHighEntropyValues) {
    navigator.userAgentData.getHighEntropyValues(['architecture'])
      .then((hints) => (hints.architecture === 'x86' ? markIntel() : markArm()))
      .catch(() => {});
  } else if (/Intel/i.test(navigator.platform || '')) {
    markIntel();
  } else {
    markArm();
  }

  /* ---------------- 粒子星座背景 ---------------- */
  const canvas = document.getElementById('constellation');
  if (!canvas || reduced) {
    canvas?.remove();
    return;
  }
  const ctx = canvas.getContext('2d');
  let nodes = [];
  let frame = 0;
  let width = 0;
  let height = 0;

  const seed = () => {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    width = window.innerWidth;
    height = window.innerHeight;
    canvas.width = Math.floor(width * dpr);
    canvas.height = Math.floor(height * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    const count = Math.min(88, Math.round((width * height) / 22000));
    nodes = Array.from({ length: count }, () => ({
      x: Math.random() * width,
      y: Math.random() * height,
      vx: (Math.random() - 0.5) * 0.22,
      vy: (Math.random() - 0.5) * 0.22,
      r: Math.random() * 1.6 + 0.5,
      hue: [214, 262, 156][Math.floor(Math.random() * 3)],
    }));
  };

  const paint = () => {
    const light = document.documentElement.dataset.theme === 'light';
    ctx.clearRect(0, 0, width, height);
    for (const node of nodes) {
      node.x += node.vx;
      node.y += node.vy;
      if (node.x < 0 || node.x > width) node.vx *= -1;
      if (node.y < 0 || node.y > height) node.vy *= -1;
    }
    for (let i = 0; i < nodes.length; i += 1) {
      for (let j = i + 1; j < nodes.length; j += 1) {
        const dx = nodes[i].x - nodes[j].x;
        const dy = nodes[i].y - nodes[j].y;
        const dist = Math.hypot(dx, dy);
        if (dist > 132) continue;
        ctx.strokeStyle = `hsla(${nodes[i].hue}, 90%, ${light ? 46 : 68}%, ${(1 - dist / 132) * 0.20})`;
        ctx.lineWidth = 1;
        ctx.beginPath();
        ctx.moveTo(nodes[i].x, nodes[i].y);
        ctx.lineTo(nodes[j].x, nodes[j].y);
        ctx.stroke();
      }
    }
    for (const node of nodes) {
      ctx.fillStyle = `hsla(${node.hue}, 92%, ${light ? 52 : 72}%, ${light ? 0.5 : 0.75})`;
      ctx.beginPath();
      ctx.arc(node.x, node.y, node.r, 0, Math.PI * 2);
      ctx.fill();
    }
    frame = requestAnimationFrame(paint);
  };

  seed();
  paint();
  window.addEventListener('resize', () => {
    cancelAnimationFrame(frame);
    seed();
    paint();
  });
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) cancelAnimationFrame(frame);
    else paint();
  });
})();
