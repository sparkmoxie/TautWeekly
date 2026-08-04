(() => {
  const progress = document.querySelector('#scroll-progress');
  const search = document.querySelector('#site-search');
  const searchable = [...document.querySelectorAll('.searchable')];
  const noResults = document.querySelector('#no-results');

  const updateProgress = () => {
    const max = document.documentElement.scrollHeight - window.innerHeight;
    const ratio = max > 0 ? Math.min(1, window.scrollY / max) : 0;
    progress.style.width = `${ratio * 100}%`;
  };

  const updateSearch = () => {
    const term = search.value.trim().toLowerCase();
    let visible = 0;
    searchable.forEach((section) => {
      const haystack = `${section.dataset.search || ''} ${section.textContent}`.toLowerCase();
      const match = !term || haystack.includes(term);
      section.classList.toggle('is-filtered', !match);
      if (match) visible += 1;
    });
    noResults.hidden = visible !== 0;
  };

  window.addEventListener('scroll', updateProgress, { passive: true });
  window.addEventListener('resize', updateProgress);
  search.addEventListener('input', updateSearch);
  document.addEventListener('keydown', (event) => {
    if (event.key === '/' && document.activeElement !== search) {
      event.preventDefault();
      search.focus();
    }
    if (event.key === 'Escape' && document.activeElement === search) {
      search.value = '';
      search.blur();
      updateSearch();
    }
  });

  document.querySelectorAll('[data-copy]').forEach((button) => {
    button.addEventListener('click', async () => {
      const target = document.querySelector(button.dataset.copy);
      if (!target) return;
      await navigator.clipboard.writeText(target.textContent);
      const original = button.textContent;
      button.textContent = 'Copied';
      setTimeout(() => { button.textContent = original; }, 1200);
    });
  });

  updateProgress();
})();
