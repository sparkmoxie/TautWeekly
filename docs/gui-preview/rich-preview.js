"use strict";

(() => {
  const media = (name) => `media/${name}`;
  let releaseScenario = "new";
  const fictionalWatchedMovies = new Set(["Spider-Man: Brand New Day", "Hadestown: The Musical"]);
  const hasWatchedMovie = (item, state) => state.hasHistory && fictionalWatchedMovies.has(item.title);
  const movies = [
    { title: "Spider-Man: Brand New Day", year: 2026, genre: "Action, Adventure, and more", critic: 89, audience: 98, art: "spider-man-brand-new-day.jpg", logo: "spider-man-brand-new-day-logo.png", summary: "Peter Parker begins a new chapter in this latest big-screen adventure." },
    { title: "The Odyssey", year: 2026, genre: "Adventure, Action, and Fantasy", critic: 94, audience: 97, art: "the-odyssey.jpg", logo: "the-odyssey-logo.png", summary: "A sweeping journey home unfolds across mythic seas and impossible trials." },
    { title: "Hadestown: The Musical", year: 2026, genre: "Music, Musical, and Drama", critic: 97, audience: 99, art: "hadestown.jpg", logo: "hadestown-logo.png", summary: "The acclaimed stage musical brings its underworld love story to the screen." },
    { title: "Motor City", year: 2026, genre: "Action, Crime, and Drama", critic: 62, audience: 66, art: "motor-city.jpg", logo: "motor-city-logo.png", summary: "A hard-edged crime story races through the streets of Detroit." },
    { title: "Orbital Drift", year: 2025, genre: "Science Fiction and Adventure", critic: 81, audience: 88, art: "the-odyssey.jpg", summary: "A fictional deep-space rescue crosses an unstable orbit." },
    { title: "Glass Harbor", year: 2024, genre: "Mystery and Drama", critic: 73, audience: 79, art: "motor-city.jpg", summary: "A fictional harbor town keeps one impossible secret." },
    { title: "Paper Suns", year: 2026, genre: "Drama and Romance", critic: null, audience: 86, art: "hadestown.jpg", summary: "A fictional summer reunion unfolds beneath painted skies." },
    { title: "Midnight Relay", year: 2025, genre: "Thriller and Crime", critic: 58, audience: null, art: "spider-man-brand-new-day.jpg", summary: "A fictional courier races a secret across the city." },
    { title: "Copper Sky", year: 2023, genre: "Western and Drama", critic: 91, audience: 84, art: "motor-city.jpg", summary: "A fictional frontier community faces a changing horizon." },
    { title: "Signal Nine", year: 2026, genre: "Action and Thriller", critic: null, audience: null, art: "spider-man-brand-new-day.jpg", summary: "A fictional emergency signal draws a crew off course." },
    { title: "Echoes of Tomorrow", year: 2024, genre: "Science Fiction and Drama", critic: 88, audience: 90, art: "the-odyssey.jpg", summary: "A fictional archive begins answering questions from the future." },
    { title: "The Last Comet", year: 2025, genre: "Adventure and Family", critic: 76, audience: 92, art: "hadestown.jpg", summary: "A fictional family follows one final light across the night sky." },
  ];
  const shows = [
    { title: "Lioness", genre: "Drama and Thriller", imdb: "8.2", art: "lioness.jpg", episodes: [["S02 EP08", "The Compass Points Home", "8.2"], ["S02 EP07", "The Devil Has Aces", "7.7"]] },
    { title: "House of the Dragon", genre: "Drama and Fantasy", imdb: "8.3", art: "house-of-the-dragon.jpg", episodes: [["S02 EP04", "The Red Dragon and the Gold", "9.4"], ["S02 EP07", "The Red Sowing", "8.8"], ["S02 EP08", "The Queen Who Ever Was", "6.5"]] },
    { title: "Ted Lasso", genre: "Comedy and Drama", imdb: "8.8", art: "ted-lasso.jpg", episodes: [["S03 EP06", "Sunflowers", "8.9"], ["S03 EP11", "Mom City", "9.3"], ["S03 EP12", "So Long, Farewell", "9.4"]] },
    { title: "Star Trek: Strange New Worlds", genre: "Science Fiction and Drama", imdb: "8.3", art: "star-trek-strange-new-worlds.jpg", episodes: [["S04 EP02", "The Griffin Incident", "7.1"], ["S02 EP09", "Subspace Rhapsody", "6.8"], ["S02 EP10", "Hegemony (1)", "8.6"]] },
    { title: "Northstar Station", genre: "Science Fiction and Mystery", imdb: "8.1", art: "star-trek-strange-new-worlds.jpg", episodes: [] },
    { title: "Copper District", genre: "Crime and Drama", imdb: null, art: "lioness.jpg", episodes: [] },
    { title: "Second Horizon", genre: "Adventure and Drama", imdb: "7.9", art: "house-of-the-dragon.jpg", episodes: [] },
    { title: "Afterlight", genre: "Mystery and Thriller", imdb: "8.5", art: "ted-lasso.jpg", episodes: [] },
    { title: "Signal Room", genre: "Drama and Science Fiction", imdb: null, art: "star-trek-strange-new-worlds.jpg", episodes: [] },
    { title: "Winter Circuit", genre: "Drama and Sport", imdb: "7.8", art: "ted-lasso.jpg", episodes: [] },
    { title: "Deep Atlas", genre: "Adventure and Fantasy", imdb: "8.0", art: "house-of-the-dragon.jpg", episodes: [] },
    { title: "Harbor Division", genre: "Crime and Thriller", imdb: "7.7", art: "lioness.jpg", episodes: [] },
  ];
  const states = {
    "demo-welcome": { name: "Manual Welcome", description: "Shared releases with the one-off onboarding introduction.", movieCount: 4, showCount: 4, welcome: true, welcomeOnly: true, stats: "none", offset: 0 },
    "demo-new": { name: "New User - No History", description: "Shared releases with first-drop onboarding and an anonymous award.", movieCount: 4, showCount: 4, welcome: true, stats: "award", offset: 0 },
    "demo-history": { name: "New User - With History", description: "Shared releases with five personal movies, one TV show, and a compact recap.", movieCount: 4, showCount: 4, statMovieCount: 5, statShowCount: 1, welcome: true, stats: "detail", winner: false, offset: 0 },
    "demo-normal": { name: "Normal Newsletter", description: "More than ten uncapped personal movie and TV rows with the winner treatment.", movieCount: 4, showCount: 4, statMovieCount: 12, statShowCount: 11, stats: "detail", winner: true, offset: 0 },
    "demo-quiet": { name: "Established Quiet", description: "Shared releases with the no-watch-activity card.", movieCount: 4, showCount: 4, stats: "quiet", offset: 0 },
    "demo-warnings": { name: "Established Warnings", description: "Shared releases with the stats-warmup notice.", movieCount: 4, showCount: 4, stats: "warmup", offset: 0 },
  };
  const files = {
    "demo-welcome": "preview-all-01-manual-welcome.html",
    "demo-new": "preview-all-02-new-user-no-history.html",
    "demo-history": "preview-all-03-new-user-with-history.html",
    "demo-normal": "preview-all-04-normal-newsletter.html",
    "demo-quiet": "preview-all-05-established-quiet.html",
    "demo-warnings": "preview-all-06-established-warmup.html",
  };
  const titleGifAssets = Object.freeze({
    none: "",
    celebrate: "celebrate.gif",
    construction: "construction.gif",
    rocket: "rocket.gif",
    tickets: "tickets.gif",
    warning: "warning.gif",
    alert: "alert.gif",
  });

  const styles = `
    :root{color-scheme:dark}*{box-sizing:border-box}body{margin:0;background:#0f0f0f;color:#fff;font:15px/1.5 Arial,Helvetica,sans-serif}.email-stage{background:#0f0f0f;padding:28px 10px 40px}.email{width:100%;max-width:640px;margin:0 auto}.header{padding:0 20px 18px}.plex{font-size:13px;font-weight:900;letter-spacing:2px;color:#fff}.plex b{color:#e5a00d;font-size:17px}.hello{padding-top:8px;font-size:30px;line-height:1.15;font-weight:800}.intro{padding-top:8px;color:#a9a9a9;line-height:1.55}.release-meta{padding:0 20px 18px}.period{color:#e5a00d;font-size:12px;font-weight:900;letter-spacing:.8px}.date{padding-top:5px;color:#666;font-size:12px}.section-label{margin:6px 20px 10px;color:#e5a00d;font-size:12px;font-weight:900;letter-spacing:1.4px}.section-title{display:block;padding-top:3px;color:#fff;font-size:24px;letter-spacing:0}.panel{margin:0 20px 24px;border:1px solid #2b2b2b;border-radius:10px;background:#181818;overflow:hidden}.welcome{border-color:#e5a00d;padding:20px 22px}.welcome-kicker,.hero-kicker,.custom-title{color:#e5a00d;font-size:11px;font-weight:900;letter-spacing:1.35px}.welcome-heading,.custom-subheading{padding-top:6px;font-size:22px;line-height:1.2;font-weight:800}.welcome-copy,.custom-body{padding-top:6px;color:#9b9b9b;font-size:13px}.custom-text-card{padding:20px 22px}.custom-text-card.no-heading .custom-body{padding-top:0}.hero{display:grid;grid-template-columns:205px minmax(0,1fr);padding:16px}.hero-poster{display:block;width:180px;height:270px;object-fit:cover;border-radius:8px}.hero-copy{min-height:270px;display:flex;flex-direction:column;padding-left:4px}.hero-icon{display:block;width:42px;height:42px;object-fit:contain}.title-logo{display:block;max-width:280px;max-height:86px;width:auto;height:auto;margin-top:8px}.hero-title{padding-top:5px;font-size:25px;line-height:1.1;font-weight:900}.genre{padding-top:5px;color:#969696;font-size:13px}.ratings{display:flex;align-items:center;flex-wrap:wrap;gap:9px;padding-top:11px;color:#e5a00d;font-size:12px;font-weight:800}.score{display:inline-flex;align-items:center;gap:4px;white-space:nowrap}.score img{width:18px;height:18px;object-fit:contain}.summary{padding-top:10px;color:#969696;font-size:13px;line-height:1.45}.plays{margin-top:auto;padding-top:12px;color:#e5a00d;font-size:12px}.grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:12px;margin:0 14px 24px}.media-card{min-width:0;border:1px solid #2b2b2b;border-radius:10px;background:#181818;overflow:hidden}.card-art{display:block;width:100%;aspect-ratio:2/1.18;object-fit:cover}.card-copy{min-height:132px;padding:12px 12px 14px}.card-title{font-size:16px;font-weight:800;line-height:1.25}.card-genre{padding-top:5px;color:#969696;font-size:12px}.episodes{padding-top:4px}.episode{padding-top:4px;color:#b0b0b0;font-size:12px;font-weight:600}.imdb{display:inline-flex;align-items:center;gap:5px;margin-left:7px;color:#e5a00d;font-size:11px;white-space:nowrap}.imdb img{width:28px;height:14px;object-fit:contain}.stats-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin:0 20px 24px}.metric{min-height:150px;padding:16px;border:1px solid #2b2b2b;border-radius:10px;background:#181818}.metric.gold{border-color:#e5a00d;background:#211a0d}.metric-icon{display:block;width:42px;height:42px;object-fit:contain}.metric-value{padding-top:9px;font-size:26px;font-weight:900}.metric-label{padding-top:3px;color:#8e8e8e;font-size:11px;text-transform:uppercase;letter-spacing:.6px}.watched-list{margin-top:11px;padding-top:7px;border-top:1px solid #292929}.watched-row{display:flex;align-items:center;gap:9px;padding:6px 0;border-bottom:1px solid #292929}.watched-row>img{width:38px;height:56px;object-fit:cover;border-radius:4px}.watched-row>div{min-width:0}.watched-row strong{display:block;font-size:12px;line-height:1.25}.watched-row small{display:block;color:#929292}.status-panel{display:flex;align-items:center;gap:14px;padding:20px}.status-panel img{width:48px;height:48px;object-fit:contain}.status-panel h2{margin:4px 0 0;font-size:20px}.status-panel p{margin:5px 0 0;color:#969696;font-size:13px}.cta{text-align:center;padding:8px 20px 18px}.cta span{display:inline-block;padding:13px 24px;border-radius:7px;background:#e5a00d;color:#111;font-size:14px;font-weight:900}.fixture-note{max-width:600px;margin:10px auto 0;padding:18px 20px 0;border-top:1px solid #242424;color:#626262;font-size:10px;line-height:1.5;text-align:center}.index{max-width:840px;margin:auto;padding:38px 24px 60px}.index-kicker{color:#e5a00d;font-size:12px;font-weight:900;letter-spacing:2px}.index h1{margin:8px 0 7px;font-size:38px;line-height:1.1}.index>p{margin:0 0 24px;color:#9b9b9b}.index-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:14px}.index-card{position:relative;min-height:230px;border:1px solid #303030;border-radius:12px;overflow:hidden;background:#181818}.index-card>img{position:absolute;inset:0;width:100%;height:100%;object-fit:cover}.index-shade{position:absolute;inset:0;background:linear-gradient(180deg,rgba(8,8,8,.08),rgba(8,8,8,.97) 82%)}.index-copy{position:absolute;inset:auto 0 0;padding:18px}.index-copy strong,.index-copy small{display:block}.index-copy strong{font-size:19px}.index-copy small{padding:3px 0 13px;color:#b8b8b8}.index-copy a{display:inline-block;padding:9px 13px;border-radius:7px;background:#e5a00d;color:#111;font-weight:900;text-decoration:none}.index-note{margin-top:22px;color:#676767;font-size:11px}
    .stats-media-stack{display:grid;gap:10px;margin:0 20px 10px}.stats-media-card{min-width:0;padding:16px;border:1px solid #2b2b2b;border-radius:10px;background:#181818}.stats-heading{display:flex;align-items:center;gap:9px;padding-bottom:7px;border-bottom:1px solid #292929}.stats-heading img{display:block;width:42px;height:42px;object-fit:contain}.stats-heading-count{font-size:18px;font-weight:800;line-height:1}.stats-heading-label{padding-top:3px;color:#8e8e8e;font-size:10px;letter-spacing:.6px;text-transform:uppercase}.stats-summary-grid{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:10px;margin:0 20px 24px}.metric.compact{min-height:178px}.personal-ratings{display:flex;align-items:center;flex-wrap:wrap;gap:7px;padding-top:4px;color:#e5a00d;font-size:10px;font-weight:700}.personal-ratings .score img{width:14px;height:14px}.personal-ratings .imdb{margin-left:0}.stats-time-eyebrow{color:#e5a00d;font-size:11px;font-weight:900;letter-spacing:1.35px}
    .stats-media-card .watched-list{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));column-gap:24px}
    @media(max-width:560px){.email-stage{padding:20px 0 32px}.header{padding-inline:14px}.hello{font-size:26px}.panel{margin-inline:12px}.section-label{margin-inline:12px}.hero{grid-template-columns:1fr;padding:0}.hero-poster{width:100%;height:188px;border-radius:0;object-position:center 28%}.hero-copy{min-height:0;padding:17px 18px 20px}.title-logo{display:none}.hero-title{font-size:23px}.grid,.stats-grid,.index-grid{grid-template-columns:1fr}.grid{margin-inline:12px}.stats-grid{margin-inline:12px}.card-art{aspect-ratio:1.75/1}.metric{min-height:136px}.index{padding:28px 14px 46px}.index h1{font-size:32px}}
    @media(max-width:560px){.stats-media-stack,.stats-summary-grid{margin-inline:12px}.stats-media-card .watched-list,.stats-summary-grid{grid-template-columns:1fr}.stats-tv-media-card .watched-list{grid-template-columns:repeat(2,minmax(0,1fr))}.metric.compact{min-height:164px}}

    .imdb{font-size:12px;font-weight:700}.personal-ratings{font-size:12px}.personal-ratings .score img{width:16px;height:16px}.stats-heading-label,.watched-row small{font-size:12px}.stats-tv-media-card .stats-heading-label{margin-bottom:-7px}.stats-time-eyebrow,.stats-summary-grid .welcome-kicker,.summary-card .welcome-kicker{font-size:12px;font-weight:900;letter-spacing:1.1px}.metric-value,.summary-card h2{font-size:27px;font-weight:800;line-height:1.1}.metric-label,.summary-card p{font-size:12px;font-weight:400;line-height:1.35;text-transform:none;letter-spacing:normal}.metric.gold .metric-icon{width:54px;height:54px}
    .hero-poster-wrap{position:relative;width:180px}.hero-poster-wrap.is-watched{padding-top:5px}.recipient-watched-desktop-badge{position:absolute;right:7px;top:0;width:26px;height:26px}.hero-title.has-logo{display:none}.hero-copy .recipient-watched-title-icon{display:none!important}.recipient-watched-title-tail{white-space:nowrap}
    @media(max-width:560px){.hero-poster-wrap,.hero-poster-wrap.is-watched{width:100%;padding-top:0}.recipient-watched-desktop-badge{display:none}.hero-title.has-logo{display:block}.hero-copy .recipient-watched-title-icon{display:inline-block!important}}
  `;

  const entities = { "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;" };
  const esc = (value) => String(value).replace(/[&<>\"]/g, (character) => entities[character]);
  const rotate = (items, offset) => items.map((_, index) => items[(index + offset) % items.length]);
  const plural = (count, singular, multiple) => count === 1 ? singular : multiple;

  function score(kind, value) {
    if (!Number.isFinite(value)) return "";
    const critic = kind === "critic";
    const icon = critic ? (value >= 60 ? "rt_ripe.png" : "rt_rotten.png") : (value >= 60 ? "rt_upright.png" : "rt_spilled.png");
    const label = critic ? "Rotten Tomatoes critic score" : "Rotten Tomatoes audience score";
    return `<span class="score"><img src="${media(icon)}" alt="${label}">${value}%</span>`;
  }

  function watchedTitle(item, state) {
    const title = esc(item.title);
    if (!hasWatchedMovie(item, state)) return title;
    const split = title.lastIndexOf(" ");
    const prefix = split >= 0 ? `<span style="vertical-align:middle;">${title.slice(0, split + 1)}</span>` : "";
    const tail = split >= 0 ? title.slice(split + 1) : title;
    return `${prefix}<span class="recipient-watched-title-tail"><span style="vertical-align:middle;">${tail}</span><img class="recipient-watched-title-icon" src="${media("watched.png")}" width="16" height="16" alt="Watched" title="Watched" style="display:inline-block;width:16px;height:16px;border:0;vertical-align:middle;margin-left:8px;"></span>`;
  }

  function movieCard(item, state) {
    return `<article class="media-card"><img class="card-art" src="${media(item.art)}" alt="${esc(item.title)} key art"><div class="card-copy"><div class="card-title">${watchedTitle(item, state)}</div><div class="card-genre">${esc(item.genre)}</div><div class="ratings"><span>${item.year}</span>${score("critic", item.critic)}${score("audience", item.audience)}</div></div></article>`;
  }

  function showCard(item) {
    const badge = (rating) => rating ? `<span class="imdb"><img src="${media("imdb.png")}" alt="IMDb">${esc(rating)}</span>` : "";
    const episodes = item.episodes.length
      ? item.episodes.slice(0, 3).map(([number, title, rating]) => `<div class="episode">${esc(number)}: ${esc(title)} ${badge(rating || item.imdb)}</div>`).join("")
      : badge(item.imdb);
    return `<article class="media-card"><img class="card-art" src="${media(item.art)}" alt="${esc(item.title)} key art"><div class="card-copy"><div class="card-title">${esc(item.title)}</div><div class="card-genre">${esc(item.genre)}</div><div class="episodes">${episodes}</div></div></article>`;
  }

  function heroBlock(item, state) {
    const label = state.latest ? "TRENDING THIS WEEK" : "HOT NEW RELEASE";
    const icon = state.latest ? "popcorn.gif" : "hot.gif";
    const logo = item.logo ? `<img class="title-logo" src="${media(item.logo)}" alt="${esc(item.title)} logo">` : "";
    const title = `<div class="hero-title${item.logo ? " has-logo" : ""}">${watchedTitle(item, state)}</div>`;
    const watched = hasWatchedMovie(item, state);
    const poster = `<div class="hero-poster-wrap${watched ? " is-watched" : ""}"><img class="hero-poster" src="${media(item.art)}" alt="${esc(item.title)} key art">${watched ? `<img class="recipient-watched-desktop-badge" src="${media("watched-desktop.png")}" width="26" height="26" alt="Watched" title="Watched">` : ""}</div>`;
    return `<section class="panel hero">${poster}<div class="hero-copy"><img class="hero-icon" src="${media(icon)}" alt=""><div class="hero-kicker">${label}</div>${logo}${title}<div class="genre">${esc(item.genre)}</div><div class="ratings"><span>${item.year}</span>${score("critic", item.critic)}${score("audience", item.audience)}</div><div class="summary">${esc(item.summary)}</div><div class="plays">${state.latest ? "Most watched across STARLIGHT CINEMA this week" : "Most-watched new release across STARLIGHT CINEMA this week"} &middot; ${state.latest ? 11 : 4} fictional plays</div></div></section>`;
  }

  function personalRating(item, kind) {
    if (kind === "movie") {
      const ratings = [];
      if (Number.isFinite(item.critic)) ratings.push(score("critic", item.critic));
      if (Number.isFinite(item.audience)) ratings.push(score("audience", item.audience));
      return ratings.length ? `<div class="personal-ratings">${ratings.join("")}</div>` : "";
    }
    return item.imdb ? `<div class="personal-ratings"><span class="imdb"><img src="${media("imdb.png")}" alt="IMDb">${esc(item.imdb)}</span></div>` : "";
  }

  function watchedRows(items, kind) {
    return items.map((item, index) => {
      const episodeCount = index === 0 ? 3 : index + 1;
      const episodeText = `${episodeCount} ${episodeCount === 1 ? "episode" : "episodes"}`;
      const secondary = kind === "movie"
        ? `<small>${esc(item.genre)}</small>${personalRating(item, kind)}`
        : `${personalRating(item, kind)}<small>${episodeText}</small>`;
      return `<div class="watched-row"><img src="${media(item.art)}" alt="${esc(item.title)} poster"><div><strong>${esc(item.title)}</strong>${secondary}</div></div>`;
    }).join("");
  }

  function statsMediaCard(items, kind) {
    if (!items.length) return "";
    const movie = kind === "movie";
    const icon = movie ? "movies.gif" : "tv.gif";
    const label = movie ? "MOVIES WATCHED" : "TV SHOWS WATCHED";
    const mediaClass = movie ? "stats-movie-media-card" : "stats-tv-media-card";
    return `<article class="stats-media-card ${mediaClass}"><div class="stats-heading"><img src="${media(icon)}" alt=""><div><div class="stats-heading-count">${items.length}</div><div class="stats-heading-label">${label}</div></div></div><div class="watched-list">${watchedRows(items, kind)}</div></article>`;
  }

  function awardMetric(winner) {
    return `<article class="metric compact${winner ? " gold" : ""}"><div class="welcome-kicker">${winner ? "YOU WON" : "THIS WEEK'S"} &middot; BINGE CHAMPION</div><img class="metric-icon" src="${media("trophy.gif")}" alt="" style="margin-top:10px"><div class="metric-value">6h 4m watched</div><div class="metric-label">7 plays &middot; 5 movies &middot; 2 TV shows: 7 episodes</div></article>`;
  }

  function timeMetric(state) {
    const movieCount = state.statMovieCount ?? state.movieCount;
    const showCount = state.statShowCount ?? state.showCount;
    return `<article class="metric compact"><div class="stats-time-eyebrow">YOU CLOCKED</div><img class="metric-icon" src="${media("clock.gif")}" alt="" style="margin-top:10px"><div class="metric-value">${movieCount * 3 + showCount + 4}h 18m</div><div class="metric-label">total watch time</div></article>`;
  }

  function awardCard(winner) {
    return `<section class="panel status-panel summary-card" style="${winner ? "border-color:#e5a00d;background:#211a0d" : ""}"><img src="${media("trophy.gif")}" alt=""><div><div class="welcome-kicker">${winner ? "YOU WON" : "THIS WEEK'S"} &middot; BINGE CHAMPION</div><h2>6h 4m watched</h2><p>7 plays &middot; 5 movies &middot; 2 TV shows: 7 episodes &middot; fictional aggregate</p></div></section>`;
  }

  function platformIcon(state) {
    return state.hasHistory ? `<img class="recipient-platform-icon" src="${media("platform-chrome.png")}" width="21" height="21" alt="Chrome" title="Chrome" style="display:inline-block;width:21px;height:21px;vertical-align:middle;margin-left:6px;">` : "";
  }

  function statsBlock(state, movieItems, showItems) {
    if (state.stats === "none") return "";
    if (state.stats === "quiet" || state.stats === "warmup") {
      const warmup = state.stats === "warmup";
      return `<div class="section-label">YOUR WEEK ON PLEX${platformIcon(state)}</div><section class="panel status-panel"><img src="${media(warmup ? "pending.gif" : "quiet.gif")}" alt=""><div><div class="welcome-kicker">${warmup ? "STATS ARE WARMING UP" : "QUIET IN THIS SECTOR"}</div><h2>${warmup ? "The sensors are online." : "No watch activity this week."}</h2><p>${warmup ? "The fictional private recap will fill in after viewing activity appears." : "The fictional recap will be ready when Demo Viewer streams again."}</p></div></section>${awardCard(false)}`;
    }
    if (state.stats === "award") return awardCard(false);
    const mediaCards = `${statsMediaCard(movieItems, "movie")}${statsMediaCard(showItems, "show")}`;
    const mediaStack = mediaCards ? `<section class="stats-media-stack">${mediaCards}</section>` : "";
    return `<div class="section-label">YOUR WEEK ON PLEX${platformIcon(state)}</div>${mediaStack}<section class="stats-summary-grid">${timeMetric(state)}${awardMetric(Boolean(state.winner))}</section>`;
  }

  function welcomeBlock(state) {
    if (!state.welcome) return "";
    return `<section class="panel welcome"><div class="welcome-kicker">WELCOME ABOARD <img src="${media("welcome.gif")}" width="18" height="18" alt="" style="vertical-align:-4px"></div><div class="welcome-heading">Access granted, Demo Viewer.</div><div class="welcome-copy">Your fictional access to STARLIGHT CINEMA is active. New additions are below, and private stats appear as the demonstration accumulates viewing history.</div></section>`;
  }

  function customTextCardValues() {
    const input = (name) => document.getElementById(`config-${name}`);
    const enabledInput = input("CustomTextCardEnabled");
    const enabled = enabledInput ? enabledInput.checked : true;
    const body = String(input("CustomTextCardBody")?.value ?? "A synthetic announcement for local assessment.").trim();
    const colorValue = String(input("CustomTextCardBorderColor")?.value ?? "#72aef7");
    const color = /^#[0-9a-f]{6}$/i.test(colorValue) ? colorValue : "#72aef7";
    const opacity = Math.max(0, Math.min(100, Number(input("CustomTextCardBorderOpacity")?.value ?? 34)));
    const requestedTitleGifID = String(input("CustomTextCardTitleGif")?.value ?? "none");
    const titleGifID = Object.hasOwn(titleGifAssets, requestedTitleGifID) ? requestedTitleGifID : "none";
    return {
      enabled: enabled && body !== "",
      color,
      opacity,
      title: String(input("CustomTextCardTitle")?.value ?? "CUSTOM TITLE").trim(),
      titleGifID,
      titleGifFile: titleGifAssets[titleGifID],
      subheading: String(input("CustomTextCardSubheading")?.value ?? "Custom subheading").trim(),
      body,
    };
  }

  function customTextCard() {
    const card = customTextCardValues();
    if (!card.enabled) return "";
    const titleGif = card.title && card.titleGifFile ? `<img class="custom-title-gif" src="${media(card.titleGifFile)}" width="18" height="18" alt="" style="vertical-align:-4px;margin-left:6px">` : "";
    const title = card.title ? `<div class="custom-title">${esc(card.title.toUpperCase())}${titleGif}</div>` : "";
    const subheading = card.subheading ? `<div class="custom-subheading" style="padding-top:${card.title ? 6 : 0}px">${esc(card.subheading)}</div>` : "";
    const body = esc(card.body).replace(/\r\n?|\n/g, "<br>");
    const border = card.opacity === 0 ? "border:0" : `border-color:${card.color}${Math.round(card.opacity * 2.55).toString(16).padStart(2, "0")}`;
    return `<section class="panel custom-text-card${card.title || card.subheading ? "" : " no-heading"}" style="${border}">${title}${subheading}<div class="custom-body">${body}</div></section>`;
  }

  function complementaryFooter(state) {
    if (state.latest) {
      return `<section class="panel status-panel summary-card"><img src="${media("genre-scifi.gif")}" width="42" height="42" alt=""><div><div class="welcome-kicker">TOP GENRE THIS WEEK</div><h2>Science Fiction</h2><p style="font-size:12px;line-height:1.35;font-weight:400;color:#8e8e8e">6h 56m watched across 2 movies</p></div></section>`;
    }
    const item = rotate(movies, state.offset)[1] || movies[0];
    return `<section class="panel status-panel summary-card"><img src="${media("popcorn.gif")}" width="42" height="42" alt=""><div><div class="welcome-kicker">TRENDING THIS WEEK</div><h2>${esc(item.title)}</h2><p>Most watched across STARLIGHT CINEMA this week &middot; 11 fictional plays</p></div></section>`;
  }

  function newsletter(state) {
    const movieItems = rotate(movies, state.offset).slice(0, state.movieCount);
    const showItems = rotate(shows, state.offset).slice(0, state.showCount);
    const statsMovieItems = rotate(movies, state.offset).slice(0, state.statMovieCount ?? state.movieCount);
    const statsShowItems = rotate(shows, state.offset).slice(0, state.statShowCount ?? state.showCount);
    const hero = movieItems[0] || movies[0];
    const releaseMovies = movieItems.slice(1, 5);
    const newTv = state.latest && Boolean(state.newTv);
    const headerLine = state.latest
      ? (newTv
        ? `0 NEW MOVIES &middot; ${showItems.length} ${plural(showItems.length, "TV TITLE", "TV TITLES")}`
        : `1 TRENDING MOVIE &middot; ${releaseMovies.length} ${plural(releaseMovies.length, "RECENT MOVIE RELEASE", "RECENT MOVIE RELEASES")}`)
      : `${state.movieCount} ${plural(state.movieCount, "NEW MOVIE", "NEW MOVIES")} &middot; ${state.showCount} ${plural(state.showCount, "TV TITLE", "TV TITLES")}`;
    const movieGrid = releaseMovies.length ? `<div class="section-label">${state.latest ? "RECENT RELEASES" : "NEW RELEASES"}<span class="section-title">Movies</span></div><section class="grid">${releaseMovies.map((item) => movieCard(item, state)).join("")}</section>` : "";
    const showGrid = showItems.length ? `<div class="section-label">${state.latest && !newTv ? "RECENT RELEASES" : "NEW RELEASES"}<span class="section-title">TV</span></div><section class="grid">${showItems.map(showCard).join("")}</section>` : "";
    const intro = state.welcomeOnly ? "Welcome to the Friday drop - here is what is new and what to expect." : "Your Friday Plex drop is here - real media presentation with a fictional private recap.";
    return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(state.name)}</title><style>${styles}</style></head><body><div style="display:none;max-height:0;overflow:hidden;opacity:0">${headerLine}</div><main class="email-stage"><div class="email"><header class="header"><div class="plex">PLE<b>X</b></div><div class="hello">Hey Demo Viewer,</div><div class="intro">${intro}</div></header>${welcomeBlock(state)}${customTextCard()}<div class="release-meta"><div class="period">${headerLine}</div><div class="date">Aug 8 - Aug 14, 2026</div></div>${heroBlock(hero, state)}${movieGrid}${showGrid}${statsBlock(state, statsMovieItems, statsShowItems)}${complementaryFooter(state)}<div class="cta"><span>OPEN PLEX &middot; DEMO ONLY</span></div><p class="fixture-note">Local visual fixture only. Public media artwork, title logos, and Rotten Tomatoes / IMDb score snapshots are shown as they appeared on Aug 14, 2026. Viewer identity, server name, watch activity, counts, and delivery state are fictional. No affiliation or endorsement is implied; no service is contacted.</p></div></main></body></html>`;
  }

  function index() {
    const cards = Object.entries(states).map(([id, state], indexValue) => {
      const art = movies[(indexValue + state.offset) % movies.length].art;
      return `<article class="index-card"><img src="${media(art)}" alt=""><div class="index-shade"></div><div class="index-copy"><strong>${esc(state.name)}</strong><small>${esc(state.description)}</small><a href="${files[id]}">Open preview</a></div></article>`;
    }).join("");
    return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>Newsletter preview index</title><style>${styles}</style></head><body><main class="index"><div class="index-kicker">TAUTWEEKLY GUI PREVIEW</div><h1>Six production-faithful email states.</h1><p>Real media presentation, varying additions, and fictional private activity. Every link stays inside this sandboxed frame.</p><section class="index-grid">${cards}</section><p class="index-note">All artwork and score assets are bundled locally. This page makes no external request.</p></main></body></html>`;
  }

  window.TautWeeklyPreviewDemo = {
    signature() {
      return JSON.stringify({ releaseScenario, card: customTextCardValues() });
    },
    setReleaseScenario(value) {
      if (!["new", "tv-only", "quiet"].includes(value)) throw new Error("Unknown fictional release scenario.");
      releaseScenario = value;
    },
    html(id) {
      if (id === "demo-index") return index();
      const state = states[id] || states["demo-normal"];
      return newsletter({ ...state, hasHistory: ["detail", "quiet"].includes(state.stats),
        latest: releaseScenario !== "new", newTv: releaseScenario === "tv-only",
        movieCount: releaseScenario === "new" ? 4 : 5 });
    },
  };
})();
