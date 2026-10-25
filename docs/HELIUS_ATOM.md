# The Helius atom

The one picture every Olo surface shares: a glowing atom (Helius, the sun at the centre) with a network growing around it, node by node, for Olo, Zeus and the people and sources that join. It stands for WEBOCTA, the Innovative Neural Network (INN): Olo Commons learning every day, checked by Zeus, used through Olo.

It appears at launch (first run and the terms screen), as the empty state of a new conversation, and as the loader while an answer is being checked. It is drawn with code on every platform (SwiftUI Canvas on the Mac, react-native-svg on the iPhone, inline SVG on the web) so it is crisp at any size and weighs nothing.

## Geometry (unit square, centre 0.5, 0.5)

- Nucleus: a disc of radius 0.07 with a soft radial glow out to 0.16. The glow breathes: radius and opacity follow a sine with a 2.8 s period.
- Three orbits: ellipses with semi axes 0.36 by 0.14, rotated 0, 60 and 120 degrees. Stroke 1 px at 25 percent white.
- Three electrons, one per orbit, each a disc of radius 0.016 with a glow of 0.04, moving around its orbit with periods 5.2 s, 6.4 s and 7.6 s (so the pattern never repeats exactly), starting at different angles.
- Network: eight nodes placed on a ring of radius 0.44 at irregular angles (seeded, fixed), each connected to the nucleus and to its two ring neighbours. Nodes appear one at a time, 0.6 s apart, with a 0.4 s ease out scale from 0 to 1; each edge draws from the nucleus outwards over 0.5 s as its node appears. Three nodes carry labels: Olo, Zeus, Helius (the rest are unlabelled). Once all eight are in, a slow pulse of light travels along one edge every 1.5 s (a small bright dot moving from the nucleus to a node and back).
- The whole drawing rotates very slowly (one turn in 90 s) so it reads as alive even when nothing else moves.

## Colour

- Background: transparent (the surface supplies it). Default surface #05070D.
- Nucleus: #FFB347 core to #FF7A18 edge; glow #FFB347 at 35 percent fading to 0.
- Orbits: white at 25 percent.
- Electrons: #7CC7FF (Zeus blue) with a glow at 45 percent.
- Network edges: white at 18 percent; the travelling pulse #FFFFFF at 80 percent.
- Nodes: Olo #9B8CFF, Zeus #7CC7FF, Helius #FFB347, unlabelled #C9D1E3 at 70 percent.
- Labels: system font, small caps feel (letter spacing 0.08 em), #C9D1E3.

## Motion rules

- Respect reduced motion: when the system asks for it, draw the final frame (all nodes in, electrons still) with the nucleus breathing only.
- Never block input: it is decoration, the screen it sits on must work while it animates.
- Loader use: a 56 pt version with the network already built and the electrons moving, no labels.
- Launch use: the full build up, which takes about 5 s, then the idle loop. Tapping or clicking anywhere skips to idle.

## Words that may sit under it

"Olo. Checked by Zeus. Learning on WEBOCTA." or, on the first run, "Welcome to Olo". No slogan claims that answers are certain.
