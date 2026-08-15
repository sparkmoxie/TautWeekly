"use strict";

(() => {
  const media = (name) => `media/${name}`;
  const movies = [
    { title: "Spider-Man: Brand New Day", year: 2026, genre: "Action, Adventure, and more", critic: 89, audience: 98, art: "spider-man-brand-new-day.jpg", logo: "spider-man-brand-new-day-logo.png", summary: "Peter Parker begins a new chapter in this latest big-screen adventure." },
    { title: "The Odyssey", year: 2026, genre: "Adventure, Action, and Fantasy", critic: 94, audience: 97, art: "the-odyssey.jpg", logo: "the-odyssey-logo.png", summary: "A sweeping journey home unfolds across mythic seas and impossible trials." },
    { title: "Hadestown: The Musical", year: 2026, genre: "Music, Musical, and Drama", critic: 97, audience: 99, art: "hadestown.jpg", logo: "hadestown-logo.png", summary: "The acclaimed stage musical brings its underworld love story to the screen." },
    { title: "Motor City", year: 2026, genre: "Action, Crime, and Drama", critic: 62, audience: 66, art: "motor-city.jpg", logo: "motor-city-logo.png", summary: "A hard-edged crime story races through the streets of Detroit." },
  ];
  const shows = [
    { title: "Lioness", genre: "Drama and Thriller", art: "lioness.jpg", episodes: [["S02 EP08", "The Compass Points Home", "8.2"], ["S02 EP07", "The Devil Has Aces", "7.7"]] },
    { title: "House of the Dragon", genre: "Drama and Fantasy", art: "house-of-the-dragon.jpg", episodes: [["S02 EP04", "The Red Dragon and the Gold", "9.4"], ["S02 EP07", "The Red Sowing", "8.8"], ["S02 EP08", "The Queen Who Ever Was", "6.5"]] },
    { title: "Ted Lasso", genre: "Comedy and Drama", art: "ted-lasso.jpg", episodes: [["S03 EP06", "Sunflowers", "8.9"], ["S03 EP11", "Mom City", "9.3"], ["S03 EP12", "So Long, Farewell", "9.4"]] },
    { title: "Star Trek: Strange New Worlds", genre: "Science Fiction and Drama", art: "star-trek-strange-new-worlds.jpg", episodes: [["S04 EP02", "The Griffin Incident", "7.1"], ["S02 EP09", "Subspace Rhapsody", "6.8"], ["S02 EP10", "Hegemony (1)", "8.6"]] },
  ];
  const states = {
    "demo-welcome": { name: "Manual Welcome", description: "One-off onboarding with two movies and one TV title.", movieCount: 2, showCount: 1, welcome: true, welcomeOnly: true, stats: "none", offset: 1 },
    "demo-new": { name: "New User - No History", description: "A first weekly drop with one movie, one TV title, and an anonymous award.", movieCount: 1, showCount: 1, welcome: true, stats: "award", offset: 2 },
    "demo-history": { name: "New User - With History", description: "Three movies, two TV titles, and a compact private recap.", movieCount: 3, showCount: 2, welcome: true, stats: "detail", offset: 3 },
    "demo-normal": { name: "Normal Newsletter", description: "Four movies, four TV titles, and the complete weekly stats treatment.", movieCount: 4, showCount: 4, stats: "detail", offset: 0 },
    "demo-quiet": { name: "Established Quiet", description: "One latest movie, one TV title, and a quiet-week recap.", movieCount: 1, showCount: 1, stats: "quiet", offset: 1, latest: true },
    "demo-warnings": { name: "Established Warnings", description: "Two movies, one TV title, and a stats warmup notice.", movieCount: 2, showCount: 1, stats: "warmup", offset: 2 },
  };
  const files = {
    "demo-welcome": "preview-all-01-manual-welcome.html",
    "demo-new": "preview-all-02-new-user-no-history.html",
    "demo-history": "preview-all-03-new-user-with-history.html",
    "demo-normal": "preview-all-04-normal-newsletter.html",
    "demo-quiet": "preview-all-05-established-quiet.html",
    "demo-warnings": "preview-all-06-established-warmup.html",
  };

  const styles = `
    :root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#0f0f0f;color:#fff;font:15px/1.5 Arial,Helvetica,sans-serif}.email-stage{background:#0f0f0f;padding:28px 10px 40px}.email{width:100%;max-width:640px;margin:0 auto}.header{padding:0 20px 18px}.plex{font-size:13px;font-weight:900;letter-spacing:2px;color:#fff}.plex b{color:#e5a00d;font-size:17px}.hello{padding-top:8px;font-size:30px;line-height:1.15;font-weight:800}.intro{padding-top:8px;color:#a9a9a9;line-height:1.55}.period{padding-top:11px;color:#e5a00d;font-size:12px;font-weight:900;letter-spacing:.8px}.date{padding-top:5px;color:#666;font-size:12px}.section-label{margin:6px 20px 10px;color:#e5a00d;font-size:12px;font-weight:900;letter-spacing:1.4px}.section-title{display:block;padding-top:3px;color:#fff;font-size:24px;letter-spacing:0}.panel{margin:0 20px 24px;border:1px solid #2b2b2b;border-radius:10px;background:#181818;overflow:hidden}.welcome{border-color:#e5a00d;padding:20px 22px}.welcome-kicker,.hero-kicker{color:#e5a00d;font-size:11px;font-weight:900;letter-spacing:1.35px}.welcome-heading{padding-top:6px;font-size:22px;font-weight:800}.welcome-copy{padding-top:6px;color:#9b9b9b;font-size:13px}.hero{display:grid;grid-template-columns:205px minmax(0,1fr);padding:16px}.hero-poster{display:block;width:180px;height:270px;object-fit:cover;border-radius:8px}.hero-copy{min-height:270px;display:flex;flex-direction:column;padding-left:4px}.hero-icon{display:block;width:42px;height:42px;object-fit:contain}.title-logo{display:block;max-width:280px;max-height:86px;width:auto;height:auto;margin-top:8px}.hero-title{padding-top:5px;font-size:25px;line-height:1.1;font-weight:900}.genre{padding-top:5px;color:#969696;font-size:13px}.ratings{display:flex;align-items:center;flex-wrap:wrap;gap:9px;padding-top:11px;color:#e5a00d;font-size:12px;font-weight:800}.score{display:inline-flex;align-items:center;gap:4px;white-space:nowrap}.score img{width:18px;height:18px;object-fit:contain}.summary{padding-top:10px;color:#969696;font-size:13px;line-height:1.45}.plays{margin-top:auto;padding-top:12px;color:#e5a00d;font-size:12px}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin:0 14px 24px}.media-card{min-width:0;border:1px solid #2b2b2b;border-radius:10px;background:#181818;overflow:hidden}.card-art{display:block;width:100%;aspect-ratio:2/1.18;object-fit:cover}.card-copy{min-height:132px;padding:12px 12px 14px}.card-title{font-size:16px;font-weight:800;line-height:1.25}.card-genre{padding-top:5px;color:#969696;font-size:12px}.episodes{padding-top:4px}.episode{padding-top:4px;color:#b0b0b0;font-size:12px;font-weight:600}.imdb{display:inline-flex;align-items:center;gap:5px;margin-left:7px;color:#e5a00d;font-size:11px;white-space:nowrap}.imdb img{width:28px;height:14px;object-fit:contain}.stats-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin:0 20px 24px}.metric{min-height:150px;padding:16px;border:1px solid #2b2b2b;border-radius:10px;background:#181818}.metric.gold{border-color:#e5a00d;background:#211a0d}.metric-icon{display:block;width:42px;height:42px;object-fit:contain}.metric-value{padding-top:9px;font-size:26px;font-weight:900}.metric-label{padding-top:3px;color:#8e8e8e;font-size:11px;text-transform:uppercase;letter-spacing:.6px}.watched-list{margin-top:11px;padding-top:7px;border-top:1px solid #292929}.watched-row{display:flex;align-items:center;gap:9px;padding:6px 0;border-bottom:1px solid #292929}.watched-row img{width:38px;height:56px;object-fit:cover;border-radius:4px}.watched-row strong{display:block;font-size:12px;line-height:1.25}.watched-row small{display:block;color:#929292}.status-panel{display:flex;align-items:center;gap:14px;padding:20px}.status-panel img{width:48px;height:48px;object-fit:contain}.status-panel h2{margin:4px 0 0;font-size:20px}.status-panel p{margin:5px 0 0;color:#969696;font-size:13px}.cta{text-align:center;padding:8px 20px 18px}.cta span{display:inline-block;padding:13px 24px;border-radius:7px;background:#e5a00d;color:#111;font-size:14px;font-weight:900}.fixture-note{max-width:600px;margin:10px auto 0;padding:18px 20px 0;border-top:1px solid #242424;color:#626262;font-size:10px;line-height:1.5;text-align:center}.index{max-width:840px;margin:auto;padding:38px 24px 60px}.index-kicker{color:#e5a00d;font-size:12px;font-weight:900;letter-spacing:2px}.index h1{margin:8px 0 7px;font-size:38px;line-height:1.1}.index>p{margin:0 0 24px;color:#9b9b9b}.index-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}.index-card{position:relative;min-height:230px;border:1px solid #303030;border-radius:12px;overflow:hidden;background:#181818}.index-card>img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}.index-shade{position:absolute;inset:0;background:linear-gradient(180deg,rgba(8,8,8,.08),rgba(8,8,8,.97) 82%)}.index-copy{position:absolute;inset:auto 0 0;padding:18px}.index-copy strong,.index-copy small{display:block}.index-copy strong{font-size:19px}.index-copy small{padding:3px 0 13px;color:#b8b8b8}.index-copy a{display:inline-block;padding:9px 13px;border-radius:7px;background:#e5a00d;color:#111;font-weight:900;text-decoration:none}.index-note{margin-top:22px;color:#676767;font-size:11px}
    @media(max-width:560px){.email-stage{padding:20px 0 32px}.header{padding-inline:14px}.hello{font-size:26px}.panel{margin-inline:12px}.section-label{margin-inline:12px}.hero{grid-template-columns:1fr;padding:0}.hero-poster{width:100%;height:188px;border-radius:0;object-position:center 28%}.hero-copy{min-height:0;padding:17px 18px 20px}.title-logo{display:none}.hero-title{font-size:23px}.grid,.stats-grid,.index-grid{grid-template-columns:1fr}.grid{margin-inline:12px}.stats-grid{margin-inline:12px}.card-art{aspect-ratio:1.75/1}.metric{min-height:136px}.index{padding:28px 14px 46px}.index h1{font-size:32px}}
  `;

  const entities = { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;" };
  const esc = (value) => String(value).replace(/[&<>\"]/g, (character) => entities[character]);
  const rotate = (items, offset) => items.map((_, index) => items[(index + offset) % items.length]);
  const plural = (count, singular, multiple) => count === 1 ? singular : multiple;

  function score(kind, value) {
    const critic = kind === "critic";
    const icon = critic ? (value >= 60 ? "rt_ripe.png" : "rt_rotten.png") : (value >= 60 ? "rt_upright.png" : "rt_spilled.png");
    const label = critic ? "Rotten Tomatoes critic score" : "Rotten Tomatoes audience score";
    return `<span class="score"><img src="${media(icon)}" alt="${label}">${value}%</span>`;
  }

  function movieCard(item) {
    return `<article class="media-card"><img class="card-art" src="${media(item.art)}" alt="${esc(item.title)} key art"><div class="card-copy"><div class="card-title">${esc(item.title)}</div><div class="card-genre">${esc(item.genre)}</div><div class="ratings"><span>${item.year}</span>${score("critic", item.critic)}${score("audience", item.audience)}</div></div></article>`;
  }

  function showCard(item) {
    const episodes = item.episodes.slice(0, 3).map(([number, title, rating]) => `<div class="episode">${esc(number)}: ${esc(title)} <span class="imdb"><img src="${media("imdb.png")}" alt="IMDb">${rating}</span></div>`).join("");
    return `<article class="media-card"><img class="card-art" src="${media(item.art)}" alt="${esc(item.title)} key art"><div class="card-copy"><div class="card-title">${esc(item.title)}</div><div class="card-genre">${esc(item.genre)}</div><div class="episodes">${episodes}</div></div></article>`;
  }

  function heroBlock(item, state) {
    const label = state.latest ? "TRENDING THIS WEEK" : "HOT NEW RELEASE";
    const icon = state.latest ? "popcorn.gif" : "hot.gif";
    const logo = item.logo ? `<img class="title-logo" src="${media(item.logo)}" alt="${esc(item.title)} logo">` : "";
    const title = item.logo ? "" : `<div class="hero-title">${esc(item.title)}</div>`;
    return `<section class="panel hero"><img class="hero-poster" src="${media(item.art)}" alt="${esc(item.title)} key art"><div class="hero-copy"><img class="hero-icon" src="${media(icon)}" alt=""><div class="hero-kicker">${label}</div>${logo}${title}<div class="genre">${esc(item.genre)}</div><div class="ratings"><span>${item.year}</span>${score("critic", item.critic)}${score("audience", item.audience)}</div><div class="summary">${esc(item.summary)}</div><div class="plays">Most-watched ${state.latest ? "title" : "new movie"} this week &middot; ${state.latest ? 11 : 4} fictional plays</div></div></section>`;
  }

  function watchedRows(items, kind) {
    return items.slice(0, 2).map((item, index) => `<div class="watched-row"><img src="${media(item.art)}" alt=""><div><strong>${esc(item.title)}</strong><small>${kind === "movie" ? `${index + 1}h ${18 + index * 23}m watched` : `${index + 2} episodes watched`}</small></div></div>`).join("");
  }

  function awardMetric(winner) {
    return `<article class="metric gold"><div class="welcome-kicker">${winner ? "YOU WON" : "THIS WEEK'S"} &middot; BINGE CHAMPION</div><img class="metric-icon" src="${media("trophy.gif")}" alt="" style="margin-top:10px"><div class="metric-value">6h 4m watched</div><div class="metric-label">5 movies &middot; 2 TV shows</div></article>`;
  }

  function awardCard(winner) {
    return `<section class="panel status-panel" style="${winner ? "border-color:#e5a00d;background:#211a0d" : ""}"><img src="${media("trophy.gif")}" alt=""><div><div class="welcome-kicker">${winner ? "YOU WON" : "THIS WEEK'S"} &middot; BINGE CHAMPION</div><h2>6h 4m watched</h2><p>5 movies &middot; 2 TV shows &middot; fictional aggregate</p></div></section>`;
  }

  function statsBlock(state, movieItems, showItems) {
    if (state.stats === "none") return "";
    if (state.stats === "quiet" || state.stats === "warmup") {
      const warmup = state.stats === "warmup";
      return `<div class="section-label">YOUR WEEK ON PLEX</div><section class="panel status-panel"><img src="${media("quiet.gif")}" alt=""><div><div class="welcome-kicker">${warmup ? "STATS ARE WARMING UP" : "QUIET IN THIS SECTOR"}</div><h2>${warmup ? "The sensors are online." : "No watch activity this week."}</h2><p>${warmup ? "The fictional private recap will fill in after viewing activity appears." : "The fictional recap will be ready when Demo Viewer streams again."}</p></div></section>${awardCard(false)}`;
    }
    if (state.stats === "award") return awardCard(false);
    return `<div class="section-label">YOUR WEEK ON PLEX</div><section class="stats-grid"><article class="metric"><img class="metric-icon" src="${media("movies.gif")}" alt=""><div class="metric-value">${state.movieCount + 3}</div><div class="metric-label">movies watched</div><div class="watched-list">${watchedRows(movieItems, "movie")}</div></article><article class="metric"><img class="metric-icon" src="${media("tv.gif")}" alt=""><div class="metric-value">${state.showCount + 2}</div><div class="metric-label">TV shows watched</div><div class="watched-list">${watchedRows(showItems, "show")}</div></article><article class="metric"><img class="metric-icon" src="${media("clock.gif")}" alt=""><div class="metric-value">${state.movieCount * 3 + state.showCount + 4}h 18m</div><div class="metric-label">total watched</div></article>${awardMetric(state.name === "Normal Newsletter")}</section>`;
  }

  function welcomeBlock(state) {
    if (!state.welcome) return "";
    return `<section class="panel welcome"><div class="welcome-kicker">WELCOME ABOARD <img src="${media("welcome.gif")}" width="18" height="18" alt="" style="vertical-align:-4px"></div><div class="welcome-heading">Access granted, Demo Viewer.</div><div class="welcome-copy">Your fictional access to STARLIGHT CINEMA is active. New additions are below, and private stats appear as the demonstration accumulates viewing history.</div></section>`;
  }

  function newsletter(state) {
    const movieItems = rotate(movies, state.offset).slice(0, state.movieCount);
    const showItems = rotate(shows, state.offset).slice(0, state.showCount);
    const hero = movieItems[0] || movies[0];
    const releaseMovies = movieItems.slice(1);
    const headerLine = `${state.movieCount} ${plural(state.movieCount, "NEW MOVIE", "NEW MOVIES")} &middot; ${state.showCount} ${plural(state.showCount, "TV TITLE", "TV TITLES")}`;
    const movieGrid = releaseMovies.length ? `<div class="section-label">${state.latest ? "LATEST RELEASES" : "NEW RELEASES"}<span class="section-title">Movies</span></div><section class="grid">${releaseMovies.map(movieCard).join("")}</section>` : "";
    const showGrid = showItems.length ? `<div class="section-label">${state.latest ? "LATEST RELEASES" : "NEW RELEASES"}<span class="section-title">TV</span></div><section class="grid">${showItems.map(showCard).join("")}</section>` : "";
    const intro = state.welcomeOnly ? "Welcome to the Friday drop - here is what is new and what to expect." : "Your Friday Plex drop is here - real media presentation with a fictional private recap.";
    return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(state.name)}</title><style>${styles}</style></head><body><main class="email-stage"><div class="email"><header class="header"><div class="plex">PLE<b>X</b></div><div class="hello">Hey Demo Viewer,</div><div class="intro">${intro}</div><div class="period">${headerLine}</div><div class="date">Aug 8 - Aug 14, 2026</div></header>${welcomeBlock(state)}${heroBlock(hero, state)}${movieGrid}${showGrid}${statsBlock(state, movieItems, showItems)}<div class="cta"><span>OPEN PLEX &middot; DEMO ONLY</span></div><p class="fixture-note">Local visual fixture only. Public media artwork, title logos, and Rotten Tomatoes / IMDb score snapshots are shown as they appeared on Aug 14, 2026. Viewer identity, server name, watch activity, counts, and delivery state are fictional. No affiliation or endorsement is implied; no service is contacted.</p></div></main></body></html>`;
  }

  function index() {
    const cards = Object.entries(states).map(([id, state], indexValue) => {
      const art = movies[(indexValue + state.offset) % movies.length].art;
      return `<article class="index-card"><img src="${media(art)}" alt=""><div class="index-shade"></div><div class="index-copy"><strong>${esc(state.name)}</strong><small>${esc(state.description)}</small><a href="${files[id]}">Open preview</a></div></article>`;
    }).join("");
    return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Newsletter preview index</title><style>${styles}</style></head><body><main class="index"><div class="index-kicker">TAUTWEEKLY GUI PREVIEW</div><h1>Six production-faithful email states.</h1><p>Real media presentation, varying additions, and fictional private activity. Every link stays inside this sandboxed frame.</p><section class="index-grid">${cards}</section><p class="index-note">All artwork and score assets are bundled locally. This page makes no external request.</p></main></body></html>`;
  }

  window.TautWeeklyPreviewDemo = {
    html(id) {
      if (id === "demo-index") return index();
      return newsletter(states[id] || states["demo-normal"]);
    },
  };
})();
