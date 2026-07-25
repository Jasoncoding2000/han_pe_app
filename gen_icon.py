"""Generate app icon v5: copper disc base + wooden sculpture stock chart on top."""
from PIL import Image, ImageDraw, ImageFont, ImageFilter, ImageChops
import math, os, random

SIZE = 1024
C = SIZE // 2
random.seed(42)

def lerp(a, b, t):
    return a + (b - a) * max(0.0, min(1.0, t))

def lerp_color(c1, c2, t):
    return tuple(int(lerp(a, b, t)) for a, b in zip(c1, c2))


def create_ceramic_disc():
    """Create a glossy ceramic/enamel disc with rich color and sharp highlights."""
    img = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    R = int(SIZE * 0.44)

    # === CERAMIC FACE (smooth, glossy, rich teal-green) ===
    face = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    pixels = face.load()

    # Ceramic base: very light teal
    base_color = (55, 175, 168)  # very light teal
    light_color = (95, 220, 210)  # bright teal
    highlight_color = (220, 252, 248)  # near-white specular

    # Light direction (top-left)
    lx, ly = -0.6, -0.7
    l_len = math.sqrt(lx*lx + ly*ly)
    lx, ly = lx/l_len, ly/l_len

    for y in range(C - R, C + R + 1):
        for x in range(C - R, C + R + 1):
            dx, dy = x - C, y - C
            dist = math.sqrt(dx*dx + dy*dy)
            if dist > R:
                continue

            # Normalized position
            nx, ny = dx / R, dy / R

            # Shallow plate shading (gentle concave curve)
            # Flat center with gentle rise toward edges
            r_sq = nx*nx + ny*ny
            nz = math.sqrt(max(0, 1 - r_sq * 0.3))  # very gentle dome
            diffuse = max(0, nx*lx + ny*ly + nz * 0.4)

            # Soft broad specular (no sharp hotspot)
            hx, hy = lx * 0.8, ly * 0.8
            h_len = math.sqrt(hx*hx + hy*hy)
            hx, hy = hx/h_len, hy/h_len
            spec_dot = max(0, nx*hx + ny*hy + nz * 0.3)
            spec = spec_dot ** 10  # very broad and soft

            # Base color with gentle diffuse lighting
            ambient = 0.50
            intensity = ambient + 0.40 * diffuse
            color = (
                int(min(255, base_color[0] * intensity + (light_color[0] - base_color[0]) * diffuse * 0.3)),
                int(min(255, base_color[1] * intensity + (light_color[1] - base_color[1]) * diffuse * 0.3)),
                int(min(255, base_color[2] * intensity + (light_color[2] - base_color[2]) * diffuse * 0.3))
            )

            # Add soft specular glow (barely visible)
            color = (
                min(255, int(color[0] + spec * 55)),
                min(255, int(color[1] + spec * 60)),
                min(255, int(color[2] + spec * 58))
            )

            # Subtle glaze variation
            glaze = math.sin(x * 0.05 + y * 0.03) * math.cos(y * 0.04 - x * 0.02)
            glaze = glaze * 3
            color = (
                max(0, min(255, color[0] + int(glaze))),
                max(0, min(255, color[1] + int(glaze))),
                max(0, min(255, color[2] + int(glaze)))
            )

            # Plate rim: gentle lip shadow near edge
            rim_start = 0.82
            if dist / R > rim_start:
                rim_t = (dist / R - rim_start) / (1.0 - rim_start)
                # Slight darken then brighten at very edge (lip)
                if rim_t < 0.6:
                    shade = 1.0 - rim_t * 0.25  # darken
                else:
                    shade = 0.85 + (rim_t - 0.6) * 0.3  # brighten at lip
                color = tuple(int(c * shade) for c in color)

            # Anti-alias at edge
            if dist > R - 1.5:
                alpha = int(255 * max(0, (R - dist) / 1.5))
            else:
                alpha = 255

            pixels[x, y] = (*color, alpha)

    img = Image.alpha_composite(img, face)

    # === RAISED RIM (subtle ceramic lip) ===
    rim = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    rim_draw = ImageDraw.Draw(rim)
    rim_r = R + 3
    # Bright edge highlight (top-left)
    for i in range(4):
        r = rim_r - i
        alpha = int(60 + i * 30)
        rim_draw.ellipse([C - r, C - r, C + r, C + r],
                        outline=(180, 230, 225, alpha))
    rim = rim.filter(ImageFilter.GaussianBlur(radius=1))
    img = Image.alpha_composite(img, rim)

    return img, R


def get_wood_color(x, y, base_dark, base_mid, base_light):
    """Get wood-grain colored pixel at (x, y)."""
    grain = math.sin(y * 0.07 + math.sin(x * 0.015) * 4)
    grain = (grain + 1) / 2
    noise = random.random() * 0.12
    fine = math.sin(x * 0.4 + y * 0.25) * 0.06
    t = grain * 0.65 + noise + fine
    if t < 0.45:
        return lerp_color(base_dark, base_mid, t / 0.45)
    else:
        return lerp_color(base_mid, base_light, (t - 0.45) / 0.55)


def create_wooden_chart_sculpture(disc_r):
    """Create a 3D wooden sculpture of a stock chart (candlestick bars)."""
    chart = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))

    # Chart area (inside disc, wider for more sparse layout)
    chart_r = int(disc_r * 0.72)
    chart_left = C - chart_r
    chart_right = C + chart_r
    chart_top = C - chart_r + int(SIZE * 0.02)
    chart_bottom = C + chart_r - int(SIZE * 0.02)
    chart_h = chart_bottom - chart_top

    # Candlestick bar parameters
    num_bars = 6
    bar_spacing = (chart_right - chart_left) // (num_bars + 1)
    bar_width = int(bar_spacing * 0.7)  # wider bars for fewer candles
    wick_width = max(4, bar_width // 5)

    # Candlestick data: (open, close, high, low) as fractions of chart height
    # Pattern: wave motion - low start, surge up, pull back down, then surge up again
    # hollow/solid pattern is inverted: bearish=hollow, bullish=solid
    candles = [
        (0.25, 0.45, 0.50, 0.18, False),  # solid, low start
        (0.43, 0.65, 0.70, 0.38, False),  # solid, surge up
        (0.62, 0.40, 0.68, 0.35, True),   # hollow, pullback
        (0.42, 0.28, 0.48, 0.22, True),   # hollow, drop more
        (0.30, 0.58, 0.65, 0.25, False),  # solid, recovery
        (0.56, 0.78, 0.85, 0.50, False),  # solid, high finish
    ]

    # Wood colors for the sculpture
    wood_dark = (110, 70, 35)
    wood_mid = (155, 105, 58)
    wood_light = (190, 140, 82)
    wood_highlight = (210, 165, 105)

    # Sculpture depth (3D extrusion)
    depth = 12  # pixels of extrusion

    # Draw each candlestick as a 3D wooden element
    for candle in candles:
        open_f, close_f, high_f, low_f, hollow = candle
        cx = chart_left + bar_spacing * (candles.index(candle) + 1)
        is_bullish = close_f > open_f

        body_top = chart_bottom - int(close_f * chart_h)
        body_bot = chart_bottom - int(open_f * chart_h)
        wick_top = chart_bottom - int(high_f * chart_h)
        wick_bot = chart_bottom - int(low_f * chart_h)

        # Ensure correct order
        if body_top > body_bot:
            body_top, body_bot = body_bot, body_top

        # Draw 3D extrusion (shadow/depth layers, back to front)
        for d in range(depth, 0, -1):
            shade = lerp(0.4, 0.7, d / depth)
            extrude_color = tuple(int(c * shade) for c in wood_dark)
            alpha = int(200 * (d / depth))

            # Wick extrusion — for hollow candles, skip body area
            wick_layer = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
            wd = ImageDraw.Draw(wick_layer)
            if hollow:
                # Upper wick only (wick_top to body_top)
                wd.rectangle([cx - wick_width//2 + d, wick_top + d,
                             cx + wick_width//2 + d, body_top + d],
                            fill=(*extrude_color, alpha))
                # Lower wick only (body_bot to wick_bot)
                wd.rectangle([cx - wick_width//2 + d, body_bot + d,
                             cx + wick_width//2 + d, wick_bot + d],
                            fill=(*extrude_color, alpha))
            else:
                wd.rectangle([cx - wick_width//2 + d, wick_top + d,
                             cx + wick_width//2 + d, wick_bot + d],
                            fill=(*extrude_color, alpha))
            chart = Image.alpha_composite(chart, wick_layer)

            # Body extrusion
            body_layer = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
            bd = ImageDraw.Draw(body_layer)
            bd.rectangle([cx - bar_width//2 + d, body_top + d,
                         cx + bar_width//2 + d, body_bot + d],
                        fill=(*extrude_color, alpha))
            chart = Image.alpha_composite(chart, body_layer)

        # Draw front face with wood grain texture
        # Wick (front face) — for hollow candles, skip the body area
        for y in range(wick_top, wick_bot + 1):
            # For hollow candles, skip wick inside body area
            if hollow and body_top <= y <= body_bot:
                continue
            for x in range(cx - wick_width//2, cx + wick_width//2 + 1):
                # Check if inside disc
                dx, dy = x - C, y - C
                if math.sqrt(dx*dx + dy*dy) > disc_r * 0.85:
                    continue
                color = get_wood_color(x, y, wood_dark, wood_mid, wood_light)
                # Lighting: top-left brighter
                lf = 1.0 - ((x - C) / (disc_r * 0.8)) * 0.12
                color = tuple(int(c * lf) for c in color)
                chart.putpixel((x, y), (*color, 240))

        # Body (front face with wood grain)
        # Hollow candles: only draw outline (border), leave center empty
        wall_thickness = max(4, bar_width // 5)
        for y in range(body_top, body_bot + 1):
            for x in range(cx - bar_width//2, cx + bar_width//2 + 1):
                dx_c, dy_c = x - C, y - C
                if math.sqrt(dx_c*dx_c + dy_c*dy_c) > disc_r * 0.85:
                    continue

                # Check if this pixel is on the border of the body
                is_left = x <= cx - bar_width//2 + wall_thickness
                is_right = x >= cx + bar_width//2 - wall_thickness
                is_top = y <= body_top + wall_thickness
                is_bot = y >= body_bot - wall_thickness
                is_border = is_left or is_right or is_top or is_bot

                if hollow and not is_border:
                    continue  # skip interior for hollow candles

                color = get_wood_color(x, y, wood_dark, wood_mid, wood_light)
                # Top face highlight
                if y == body_top:
                    color = tuple(min(255, int(c * 1.25)) for c in color)
                elif x == cx - bar_width//2:
                    color = tuple(min(255, int(c * 1.1)) for c in color)
                elif x == cx + bar_width//2 or y == body_bot:
                    color = tuple(int(c * 0.75) for c in color)
                chart.putpixel((x, y), (*color, 245))

    # Add carved edge highlights (top-left light catch on all elements)
    highlight = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    h_draw = ImageDraw.Draw(highlight)
    for i, (open_f, close_f, high_f, low_f, hollow) in enumerate(candles):
        cx = chart_left + bar_spacing * (i + 1)
        body_top = chart_bottom - int(close_f * chart_h)
        body_bot = chart_bottom - int(open_f * chart_h)
        if body_top > body_bot:
            body_top, body_bot = body_bot, body_top
        # Top edge highlight line
        h_draw.line([(cx - bar_width//2, body_top), (cx + bar_width//2, body_top)],
                   fill=(230, 210, 175, 100), width=2)
        # Left edge highlight
        h_draw.line([(cx - bar_width//2, body_top), (cx - bar_width//2, body_bot)],
                   fill=(220, 200, 165, 70), width=1)

    chart = Image.alpha_composite(chart, highlight)

    # Add carved shadow (bottom-right)
    shadow = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    s_draw = ImageDraw.Draw(shadow)
    for i, (open_f, close_f, high_f, low_f, hollow) in enumerate(candles):
        cx = chart_left + bar_spacing * (i + 1)
        body_top = chart_bottom - int(close_f * chart_h)
        body_bot = chart_bottom - int(open_f * chart_h)
        if body_top > body_bot:
            body_top, body_bot = body_bot, body_top
        # Bottom edge shadow
        s_draw.line([(cx - bar_width//2 + 2, body_bot + 2),
                    (cx + bar_width//2 + 2, body_bot + 2)],
                   fill=(30, 20, 10, 80), width=3)
        # Right edge shadow
        s_draw.line([(cx + bar_width//2 + 2, body_top + 2),
                    (cx + bar_width//2 + 2, body_bot + 2)],
                   fill=(30, 20, 10, 60), width=2)
    shadow = shadow.filter(ImageFilter.GaussianBlur(radius=2))
    chart = Image.alpha_composite(chart, shadow)

    return chart


def add_drop_shadow(img):
    """Soft drop shadow."""
    alpha = img.split()[3]
    shadow_alpha = alpha.filter(ImageFilter.GaussianBlur(radius=16))
    shadow_alpha = ImageChops.offset(shadow_alpha, 0, 10)
    shadow = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 0))
    layer = Image.new('RGBA', (SIZE, SIZE), (0, 0, 0, 80))
    shadow.paste(layer, mask=shadow_alpha)
    return Image.alpha_composite(shadow, img)


def main():
    # 1. Ceramic/enamel disc
    disc, R = create_ceramic_disc()

    # 2. Wooden chart sculpture on top
    chart = create_wooden_chart_sculpture(R)
    disc = Image.alpha_composite(disc, chart)

    # 3. Drop shadow
    disc = add_drop_shadow(disc)

    out_path = os.path.join(os.path.dirname(__file__), 'assets', 'app_icon.png')
    disc.save(out_path, 'PNG')
    print(f"Saved to {out_path}")
    print(f"Size: {disc.size}, Mode: {disc.mode}")


if __name__ == '__main__':
    main()
