const stage = document.getElementById('stage');
const avatar = document.getElementById('avatar');

const clamp = (v, a, b) => Math.max(a, Math.min(b, v));

let dragging = false;
let lastX = 0, lastY = 0;

let rot = 0;
let scale = 0.2;

let velX = 0;
let velY = 0;

let velBgA = 0;
let velBgShift = 0;
let bgA = 210;
let bgH1 = 280;
let bgH2 = 40;
let bgH3 = 160;

const sound1 = document.getElementById('sound1');
const sound2 = document.getElementById('sound2');

function fakeSwipe(dx, dy, touchBoost) {
    sound2.currentTime = 0;
    sound2.play();
    rot += dx * 0.25 * touchBoost;
    scale += (dx - dy) * 0.001 * touchBoost;

    velX = dx * 0.15 * touchBoost;
    velY = (dx - dy) * 0.002 * touchBoost;

    velBgA = dx * 0.1 * touchBoost / 2;
    velBgShift = (dx * 0.2 - dy * 0.15) * touchBoost / 2;

}

let fakeStarted = false;
const pressBtn = document.getElementById('pressBtn');

pressBtn.addEventListener('click', () => {
    pressBtn.classList.add('fade-out');
        setTimeout(() => {
        pressBtn.remove();
    }, 300);

    sound1.currentTime = 0;
    sound1.play();


    setTimeout(() => {
        if (fakeStarted) return;
        fakeStarted = true;
        fakeSwipe(1108.5, 400, 0.1);
    }, 2200);

});


function animate() {
    let MAX_SCALE;

    const screenMax = Math.max(window.innerWidth, window.innerHeight);

    const baseSize = Math.max(
        avatar.offsetWidth,
        avatar.offsetHeight
    );

    MAX_SCALE = screenMax / baseSize;

    if (!dragging) {
        rot += velX;
        scale += velY;

        velX *= 0.95;
        velY *= 0.95;

        if (Math.abs(velX) < 0.001) velX = 0;
        if (Math.abs(velY) < 0.001) velY = 0;

        bgA += velBgA;
        const shift = velBgShift;

        bgH1 += shift;
        bgH2 += shift * 1.1;
        bgH3 -= shift * 0.9;

        velBgA *= 0.95;
        velBgShift *= 0.95;

        if (Math.abs(velBgA) < 0.001) velBgA = 0;
        if (Math.abs(velBgShift) < 0.001) velBgShift = 0;

    }

    scale = clamp(scale, 0.2, MAX_SCALE);

    avatar.style.transform = `rotate(${rot}deg) scale(${scale})`;

    document.documentElement.style.setProperty('--bg-a', bgA);
    document.documentElement.style.setProperty('--bg-h1', bgH1);
    document.documentElement.style.setProperty('--bg-h2', bgH2);
    document.documentElement.style.setProperty('--bg-h3', bgH3);

    requestAnimationFrame(animate);
}

requestAnimationFrame(animate);

stage.addEventListener('pointerdown', e => {
    dragging = true;
    stage.setPointerCapture(e.pointerId);
    lastX = e.clientX;
    lastY = e.clientY;
});

stage.addEventListener('pointermove', e => {
    if (!dragging) return;

    const dx = e.clientX - lastX;
    const dy = e.clientY - lastY;

    lastX = e.clientX;
    lastY = e.clientY;

    const touchBoost = e.pointerType === "touch" ? 2 : 1;

    rot += dx * 0.25 * touchBoost;
    scale += (dx - dy) * 0.001 * touchBoost;

    velX = dx * 0.15 * touchBoost;
    velY = (dx - dy) * 0.002 * touchBoost;

    bgA += dx * 0.1 * touchBoost;

    const shift = (dx * 0.2 - dy * 0.15) * touchBoost;
    bgH1 += shift;
    bgH2 += shift * 1.1;
    bgH3 -= shift * 0.9;
});

stage.addEventListener('pointerup', () => {
    dragging = false;
});

stage.addEventListener('pointercancel', () => {
    dragging = false;
});