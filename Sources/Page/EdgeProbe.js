// Works out which color the strip should take, from styles alone, painting nothing.
//
// Not everything that touches the top edge counts. A page like a feed has cards and columns
// scrolling under the strip; following those would flip the strip's color with every card. So at
// five points across the edge the script finds the element whose background shows there, and only
// two kinds can set the color. A pinned element, fixed or sticky, stays put while the page scrolls:
// a sticky header, or an app's sidebar. A plain colored column with a pinned layer in front of it
// counts too, which is how GitHub builds its sidebar. An invisible layer does not count, and neither
// does anything less than 12px tall at the edge: a site's loading bar is pinned and full width, and
// would otherwise turn the strip its color whenever a page loads slowly. A band spans nearly the full width: a hero, a full-bleed
// section, often just the page's backdrop. Pinned beats scrolling, a band beats a column, then the
// wider wins. Anything else, a card or a column passing by, leaves the page's own background.
//
// The report, sent when it changes, is "r,g,b", "page", or "unknown:<n>:<look>" when a band is an
// image, gradient or other painted element: n numbers the element and look is a hash of its
// styles and of what is in front of it, so the native side can remember each look it has seen.
// Translucent colors are composited through the elements behind them, a blurred backdrop
// included, since a blur keeps the average color; a header that blurs its backdrop also adds
// "|<opacity>" of its own tint, so the strip can be the same material rather than a lid on it.
// A vertical gradient counts as the color of its top stop. A pinned element is also searched for
// what hit-testing skips, layers that ignore the pointer and pseudo-elements, which is how a bar
// with nothing but a fading scrim behind it is read. Colors outside sRGB notation, such as oklch,
// are converted by filling one pixel of a detached canvas. A video never counts, and neither does
// a painted element narrower than a band, since a snapshot could not tell its part of the edge
// from the rest.
//
// Asking where elements are makes the page bring its layout up to date, which is real work on a
// busy page, so probing is kept rare. Load, resize and scroll probe at most ten times a second,
// and once more shortly after the last of them to catch a header that was still fading. While
// scrolling, each frame also takes a glance, one hit test and a few style reads, and probes at
// once if it differs, so a header restyled by the page's scroll handler and the strip change in
// the same frame. A transition is read for where it is going: the report ends in "~<ms>", the
// time the page will take, and the strip fades over the same time. The start of a transition on
// an element of the last probe probes at once, and the end of any on a property that can change
// the edge probes once. Pages also change with no
// such event: a client-rendered header arrives late, a route or theme changes. Those follow a
// moment that is known: the load, a click, a key, a change of the system's color scheme, a return
// from the back-forward cache, or `aeroEdgeProbe()`, which the native side calls when the address
// changes without a new page. Each such moment is followed by five probes spread over eight
// seconds, and then nothing until the next one, so an idle page is never probed and a hidden one
// waits until it is shown. A probe of a page whose layout is up to date took 0.07ms on a page of
// 20,000 elements. A mutation observer would notice more, but measured on the same page it nearly
// doubled the cost of a burst of DOM changes, so there is none. It never listens to animations
// either; a page full of them would be probed on every frame.
//
// The script runs in the isolated client world, where the page's own scripts can neither see it
// nor send reports in its name.
//
// Reports go to the message handler named "edge"; see EdgeChangeRouter in PageEdge.swift.
(() => {
    const painted = /^(IMG|CANVAS|PICTURE|SVG|IFRAME|EMBED|OBJECT)$/i;
    const edgeProperty = /^(background|opacity|transform|visibility|height|top)/;
    const blurred = /blur\((?!0(px)?\))/;
    const numbers = new WeakMap(), parsed = new Map();
    let pinned = new WeakMap(), pixel;
    let last, count = 0, probeTimer = 0, settleTimer = 0, probedAt = 0;
    // What the last probe walked through, and what those looked like, for `glance`.
    let touched = new Set(), watched = [], seen = '', frame = 0, glide = 0;
    let followUps = [], missed = false;

    function number(element) {
        if (!numbers.has(element)) numbers.set(element, ++count);
        return numbers.get(element);
    }

    // Where an element's running transitions will leave it. A header fades to its new color
    // over a few hundred milliseconds; reading the color it has now would make the strip trail
    // it, learning of the change step by step. Reading where it is going, and how long it will
    // take, lets the strip set off for the same color at the same moment and arrive together.
    function heading(element) {
        const to = {};
        for (const animation of element.getAnimations ? element.getAnimations() : []) {
            const property = animation.transitionProperty;
            if (property !== 'background-color' && property !== 'opacity') continue;
            const frames = animation.effect.getKeyframes(), final = frames[frames.length - 1] || {};
            if (property === 'opacity') to.opacity = Number(final.opacity); else to.backgroundColor = final.backgroundColor;
            glide = Math.max(glide, (animation.effect.getComputedTiming().endTime || 0) - (animation.currentTime || 0));
        }
        return to;
    }

    // Names a painted element and its look: its own styles and the color in front of it.
    function unknown(element, style, front) {
        number(element);
        const image = style.backgroundImage;
        const look = [image.length, image.slice(0, 200), style.backgroundColor, Number(style.opacity).toFixed(1),
            (element.currentSrc || '').slice(-200), front].join('|');
        let hash = 0;
        for (let i = 0; i < look.length; i++) hash = (hash * 31 + look.charCodeAt(i)) | 0;
        return 'unknown:' + numbers.get(element) + ':' + (hash >>> 0).toString(36);
    }

    // A computed color as [red, green, blue, alpha]; null when not even a canvas can read it.
    function rgba(color) {
        if (color.startsWith('rgb')) {
            const [red, green, blue, alpha = 1] = color.match(/[\d.]+/g).map(Number);
            return [red, green, blue, alpha];
        }
        if (!parsed.has(color)) {
            if (parsed.size > 200) parsed.clear();
            if (!pixel) {
                const canvas = document.createElement('canvas');
                canvas.width = canvas.height = 1;
                pixel = canvas.getContext('2d', { willReadFrequently: true });
            }
            pixel.fillStyle = '#010203';
            pixel.fillStyle = color;
            let value = null;
            if (pixel.fillStyle !== '#010203') {
                pixel.clearRect(0, 0, 1, 1);
                pixel.fillRect(0, 0, 1, 1);
                const [red, green, blue, alpha] = pixel.getImageData(0, 0, 1, 1).data;
                value = [red, green, blue, alpha / 255];
            }
            parsed.set(color, value);
        }
        return parsed.get(color);
    }

    function isPinned(element) {
        if (!pinned.has(element)) {
            let found = false;
            for (let e = element; e && e !== document.documentElement && !found; e = e.parentElement) {
                const position = getComputedStyle(e).position;
                found = position === 'fixed' || position === 'sticky';
            }
            pinned.set(element, found);
        }
        return pinned.get(element);
    }

    // The color a vertical gradient shows along its top edge, its first stop or, running upward,
    // its last; null for any other image, which only pixels can tell.
    function gradientTop(image) {
        if (!image.startsWith('linear-gradient(')) return null;
        const parts = [];
        let depth = 0, start = 16;
        for (let i = 16; i < image.length; i++) {
            const c = image[i];
            if (c === '(') depth++;
            else if (c === ',' && depth === 0) { parts.push(image.slice(start, i)); start = i + 1; }
            else if (c === ')' && depth-- === 0) {
                if (i !== image.length - 1) return null;
                parts.push(image.slice(start, i));
            }
        }
        let direction = 'to bottom';
        if (/^\s*(to\s|-?[\d.]+(deg|turn|rad|grad))/.test(parts[0] || '')) direction = parts.shift().trim();
        const down = direction === 'to bottom' || direction === '180deg';
        if (!down && direction !== 'to top' && direction !== '0deg') return null;
        const stop = down ? parts[0] : parts[parts.length - 1];
        return stop ? rgba(stop.trim().replace(/(\s+-?[\d.]+(%|px))+$/, '')) : null;
    }

    // What a pinned element paints that hit-testing skips: layers set to ignore the pointer,
    // such as a scrim of blurs and a fading tint laid behind a bar, and its pseudo-elements.
    function hiddenLayers(element, x) {
        const layers = [];
        let seen = 0;
        for (const child of element.querySelectorAll('*')) {
            if (++seen > 60) break;
            const style = getComputedStyle(child);
            if (style.pointerEvents !== 'none' || (style.position !== 'absolute' && style.position !== 'fixed')) continue;
            const box = child.getBoundingClientRect();
            if (box.left <= x && box.right >= x && box.top <= 1 && box.bottom - Math.max(box.top, 0) >= 12)
                layers.push([child, style, true]);
        }
        const width = element.getBoundingClientRect().width;
        for (const pseudo of ['::before', '::after']) {
            const style = getComputedStyle(element, pseudo);
            if (style.content === 'none' || (style.position !== 'absolute' && style.position !== 'fixed')) continue;
            if (parseFloat(style.top) <= 1 && parseFloat(style.height) >= 12 && parseFloat(style.width) >= width * 0.9)
                layers.push([element, style, false]);
        }
        return layers;
    }

    // What shows at one point of the top edge: the answer, the element that owns it, and whether
    // it stays put. Sites often color a plain column and pin a transparent layer inside it, so the
    // owner also counts as pinned when something visible, pinned and no wider sits in front of it.
    // A header that blurs what is behind it is a material rather than a color: the answer then
    // ends in "|" and how opaque the header's own tint is, and the color is still everything
    // blended, which is what the eye averages to.
    function at(x) {
        let r = 0, g = 0, b = 0, a = 0, owner = null, glass = null;
        const front = [];
        const result = (answer, element, isPainted) => {
            const own = owner || element, width = own.getBoundingClientRect().width;
            const stays = isPinned(own) || front.some(e => isPinned(e) && e.getBoundingClientRect().width <= width + 2);
            return { answer: glass === null ? answer : answer + '|' + glass.toFixed(2), width, stays, isPainted };
        };
        // Adds one layer. Returns the result when the walk ends at it. `isElement` is false for a
        // pseudo-element, whose transitions cannot be asked for.
        const paint = (element, style, isPaintedTag, inFront, isElement) => {
            const to = isElement ? heading(element) : {};
            if (isElement) touched.add(element);
            const opacity = to.opacity ?? Number(style.opacity);
            if (opacity === 0) return null;
            let color = rgba(to.backgroundColor ?? style.backgroundColor), image = style.backgroundImage;
            const top = image === 'none' ? null : gradientTop(image);
            if (top && color) {
                const alpha = top[3] + color[3] * (1 - top[3]);
                color = alpha ? [0, 1, 2].map(i => (top[i] * top[3] + color[i] * color[3] * (1 - top[3])) / alpha).concat(alpha) : color;
                image = 'none';
            }
            if (isPaintedTag || image !== 'none' || !color) {
                // Under a header of glass the strip blurs what is really there, so its own tint
                // is the answer and no picture of the page is needed.
                if (glass !== null && glass >= 0.5) return result([r, g, b].map(v => Math.round(v / a)).join(','), element, false);
                const ahead = [r, g, b].map(v => Math.round(v / 8)).join(',') + ',' + a.toFixed(1);
                return result(unknown(element, style, ahead), element, true);
            }
            const [red, green, blue, alpha] = color;
            const cover = (1 - a) * alpha * opacity;
            if (!owner && cover >= 0.5) owner = element;
            if (!owner && inFront && style.visibility !== 'hidden') front.push(element);
            r += cover * red; g += cover * green; b += cover * blue; a += cover;
            return a > 0.99 ? result([r, g, b].map(v => Math.round(v / a)).join(','), element, false) : null;
        };
        for (const element of document.elementsFromPoint(x, 1)) {
            // A sliver along the edge, a loading bar or an accent stripe, is not the top of the page.
            const box = element.getBoundingClientRect();
            if (box.bottom - Math.max(box.top, 0) < 12) continue;
            if (element.tagName === 'VIDEO') return null;
            const style = getComputedStyle(element);
            const layers = [[element, style, true]];
            if (style.position === 'fixed' || style.position === 'sticky') layers.push(...hiddenLayers(element, x));
            let blurs = false;
            for (const [layer, layerStyle, isElement] of layers) {
                blurs ||= blurred.test(layerStyle.backdropFilter || layerStyle.webkitBackdropFilter || '');
                const isSelf = layerStyle === style;
                const ended = paint(layer, layerStyle, isSelf && painted.test(element.tagName), isSelf, isElement);
                if (ended) return ended;
            }
            if (blurs && glass === null) glass = a;
        }
        // A transparent document canvas still paints in the system color scheme. Blend the
        // accumulated layers into that canvas instead of discarding their visible tint.
        if (a > 0 && owner) {
            const dark = getComputedStyle(document.documentElement).colorScheme.includes('dark')
                || matchMedia('(prefers-color-scheme: dark)').matches;
            const canvas = dark ? 0 : 255;
            return result([r, g, b].map(v => Math.round(v + (1 - a) * canvas)).join(','), owner, false);
        }
        return null;
    }

    // What is pinned is looked up afresh each time: a header that only becomes fixed once the
    // page scrolls must not stay remembered as loose.
    function probe() {
        clearTimeout(probeTimer);
        probeTimer = 0;
        probedAt = performance.now();
        pinned = new WeakMap();
        touched = new Set();
        glide = 0;
        // Pinned beats scrolling, since it stays; among equals a band beats a column, then the wider wins.
        let answer = 'page', best = 0;
        for (const f of [0.02, 0.25, 0.5, 0.75, 0.98]) {
            const found = at(Math.floor(innerWidth * f));
            if (!found) continue;
            const isBand = found.width >= innerWidth * 0.9;
            if (!isBand && (!found.stays || found.isPainted)) continue;
            const rank = (found.stays ? 2 : 0) + (isBand ? 1 : 0) + found.width / (innerWidth * 10);
            if (rank > best) { answer = found.answer; best = rank; }
        }
        // "~<ms>" is how long the page will take to get there; see `heading`.
        if (answer !== last) webkit.messageHandlers.edge.postMessage(glide > 20 ? answer + '~' + Math.round(glide) : answer);
        last = answer;
        watched = [...touched].slice(0, 12);
        seen = glance();
    }

    // What a full probe would most likely answer differently about, cheaply enough to ask every
    // frame of a scroll: which elements are at the middle of the edge, and the styles of the ones
    // the last probe walked through. A running transition reads as one state, not sixty.
    function glance() {
        return document.elementsFromPoint(innerWidth >> 1, 1).slice(0, 6).map(number).join(',') + '|' + watched.map(element => {
            const style = getComputedStyle(element), moving = element.getAnimations ? element.getAnimations().length : 0;
            return (moving ? 'moving' + moving : style.backgroundColor + style.opacity + style.backgroundImage.slice(0, 160)) + style.position;
        }).join('|');
    }

    function request(settle) {
        if (!probeTimer) probeTimer = setTimeout(probe, Math.max(0, 100 - (performance.now() - probedAt)));
        if (!settle) return;
        clearTimeout(settleTimer);
        settleTimer = setTimeout(probe, 400);
    }

    // Something happened that pages answer by changing, a little later and with no event.
    function attend() {
        followUps.forEach(clearTimeout);
        followUps = [300, 1000, 2000, 4000, 8000].map(delay => setTimeout(() => {
            if (document.hidden) missed = true; else probe();
        }, delay));
    }

    for (const type of ['scroll', 'resize'])
        addEventListener(type, () => request(true), { passive: true, capture: true });
    // A page restyles its header in its own scroll handler, which has run by the time the frame's
    // animation callbacks do. Probing then, only if a glance says something changed, lets the
    // strip change in the same frame as the header rather than up to a tenth of a second later.
    addEventListener('scroll', () => {
        if (!frame) frame = requestAnimationFrame(() => { frame = 0; if (glance() !== seen) probe(); });
    }, { passive: true, capture: true });
    // The start of a transition on something the last probe walked through: read where it is going.
    addEventListener('transitionrun', event => {
        if (edgeProperty.test(event.propertyName) && watched.includes(event.target)) probe();
    }, true);
    for (const type of ['load', 'DOMContentLoaded'])
        addEventListener(type, () => { request(true); attend(); }, { passive: true, capture: true });
    for (const type of ['pointerdown', 'keydown'])
        addEventListener(type, attend, { passive: true, capture: true });
    matchMedia('(prefers-color-scheme: dark)').addEventListener('change', attend);
    addEventListener('transitionend', event => { if (edgeProperty.test(event.propertyName)) request(false); }, true);
    // A page brought back from the back-forward cache keeps `last`, but the strip starts over.
    addEventListener('pageshow', event => { if (event.persisted) { last = undefined; request(true); attend(); } });
    document.addEventListener('visibilitychange', () => {
        if (!document.hidden && missed) { missed = false; attend(); }
    });
    globalThis.aeroEdgeProbe = () => { request(true); attend(); };
})();
