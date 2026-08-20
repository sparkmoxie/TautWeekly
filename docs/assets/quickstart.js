(() => {
  document.documentElement.classList.add('quickstart-ready');

  const page = document.querySelector('.quickstart');
  if (!page) return;

  const progress = document.querySelector('#scroll-progress');
  const percent = document.querySelector('#scroll-percent');
  const search = document.querySelector('#quickstart-search');
  const clear = document.querySelector('#search-clear');
  const searchable = [...document.querySelectorAll('.searchable')];
  const noResults = document.querySelector('#no-results');
  const navPanel = document.querySelector('[data-quickstart-nav]');
  const navLinks = [...document.querySelectorAll('.guide-nav a[href^="#"]')];
  const menuToggle = document.querySelector('#menu-toggle');
  const menuClose = document.querySelector('#menu-close');
  const scrim = document.querySelector('#nav-scrim');
  const mobileQuery = window.matchMedia('(max-width: 1100px)');

  const setActiveNav = (hash) => {
    navLinks.forEach((link) => {
      const active = link.hash === hash;
      link.classList.toggle('active', active);
      if (active) link.setAttribute('aria-current', 'location');
      else link.removeAttribute('aria-current');
    });
  };

  const updateActiveNav = () => {
    const threshold = Math.min(window.innerHeight * .33, 260);
    const candidates = navLinks
      .map((link) => ({ link, section: document.querySelector(link.hash) }))
      .filter(({ section }) => section && !section.classList.contains('is-filtered'));
    if (!candidates.length) return;
    let current = candidates[0];
    candidates.forEach((candidate) => {
      if (candidate.section.getBoundingClientRect().top <= threshold) current = candidate;
    });
    setActiveNav(current.link.hash);
  };

  const updateProgress = () => {
    const root = document.documentElement;
    const maximum = Math.max(1, root.scrollHeight - root.clientHeight);
    const value = Math.max(0, Math.min(100, root.scrollTop / maximum * 100));
    if (progress) progress.style.width = `${value}%`;
    if (percent) percent.textContent = `${Math.round(value)}%`;
    updateActiveNav();
  };

  const updateSearch = () => {
    if (!search) return;
    const terms = search.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
    let visible = 0;
    searchable.forEach((section) => {
      const haystack = `${section.dataset.search || ''} ${section.innerText}`.toLowerCase();
      const matches = terms.every((term) => haystack.includes(term));
      section.classList.toggle('is-filtered', !matches);
      if (matches) visible += 1;
    });
    if (noResults) noResults.hidden = visible !== 0;
    if (clear) clear.hidden = terms.length === 0;
    updateActiveNav();
  };

  const setMenuState = (open, restoreFocus = false) => {
    if (!navPanel || !menuToggle) return;
    const next = Boolean(open && mobileQuery.matches);
    page.classList.toggle('menu-open', next);
    menuToggle.setAttribute('aria-expanded', String(next));
    navPanel.inert = mobileQuery.matches && !next;
    navPanel.setAttribute('aria-hidden', String(mobileQuery.matches && !next));
    if (next) {
      window.requestAnimationFrame(() => menuClose?.focus());
    } else if (restoreFocus) {
      menuToggle.focus();
    }
  };

  const syncViewport = () => {
    if (!mobileQuery.matches) {
      page.classList.remove('menu-open');
      menuToggle?.setAttribute('aria-expanded', 'false');
      if (navPanel) {
        navPanel.inert = false;
        navPanel.setAttribute('aria-hidden', 'false');
      }
    } else {
      setMenuState(page.classList.contains('menu-open'));
    }
    updateProgress();
  };

  menuToggle?.addEventListener('click', () => {
    setMenuState(!page.classList.contains('menu-open'));
  });
  menuClose?.addEventListener('click', () => setMenuState(false, true));
  scrim?.addEventListener('click', () => setMenuState(false, true));
  navLinks.forEach((link) => link.addEventListener('click', () => {
    setActiveNav(link.hash);
    setMenuState(false);
  }));

  if ('IntersectionObserver' in window) {
    const observed = navLinks
      .map((link) => document.querySelector(link.hash))
      .filter(Boolean);
    const observer = new IntersectionObserver((entries) => {
      const visible = entries
        .filter((entry) => entry.isIntersecting && !entry.target.classList.contains('is-filtered'))
        .sort((a, b) => b.intersectionRatio - a.intersectionRatio)[0];
      if (!visible) return;
      setActiveNav(`#${visible.target.id}`);
    }, { rootMargin: '-20% 0px -65% 0px', threshold: [0, .15, .4] });
    observed.forEach((section) => observer.observe(section));
  }

  document.querySelectorAll('.command, .command-block, pre.code').forEach((block, index) => {
    if (block.querySelector('[data-copy]')) return;
    if (!block.id) block.id = `quickstart-command-${index + 1}`;
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'quickstart-copy';
    button.dataset.copy = `#${block.id}`;
    button.setAttribute('aria-label', 'Copy command');
    button.textContent = 'Copy';
    block.append(button);
  });

  document.querySelectorAll('.code').forEach((block, index) => {
    const target = block.querySelector('pre');
    const button = block.querySelector('.copy');
    if (!target || !button || button.dataset.copy) return;
    if (!target.id) target.id = `quickstart-code-${index + 1}`;
    button.dataset.copy = `#${target.id}`;
    button.setAttribute('aria-label', 'Copy command');
  });

  document.querySelectorAll('[data-copy]').forEach((button) => {
    button.addEventListener('click', async () => {
      const target = document.querySelector(button.dataset.copy);
      if (!target) return;
      const clone = target.cloneNode(true);
      clone.querySelectorAll('button').forEach((item) => item.remove());
      const original = button.textContent;
      try {
        await navigator.clipboard.writeText(clone.textContent.trim());
        button.textContent = 'Copied';
      } catch {
        button.textContent = 'Select text';
      }
      window.setTimeout(() => { button.textContent = original; }, 1200);
    });
  });

  search?.addEventListener('input', updateSearch);
  clear?.addEventListener('click', () => {
    search.value = '';
    updateSearch();
    search.focus();
  });
  window.addEventListener('scroll', updateProgress, { passive: true });
  window.addEventListener('resize', syncViewport);
  mobileQuery.addEventListener?.('change', syncViewport);
  document.addEventListener('keydown', (event) => {
    const target = event.target;
    const editing = target instanceof HTMLElement && (
      target.matches('input, textarea, select') || target.isContentEditable
    );
    if (event.key === '/' && search && !editing) {
      event.preventDefault();
      search.focus();
    }
    if (event.key === 'Escape') {
      if (page.classList.contains('menu-open')) {
        setMenuState(false, true);
      } else if (search && document.activeElement === search) {
        search.value = '';
        search.blur();
        updateSearch();
      }
    }
    if (event.key === 'Tab' && page.classList.contains('menu-open') && navPanel) {
      const focusable = [...navPanel.querySelectorAll('button, a[href]')]
        .filter((item) => !item.hidden && !item.inert);
      if (!focusable.length) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    }
  });

  if (clear) clear.hidden = true;
  syncViewport();
  updateSearch();
})();
