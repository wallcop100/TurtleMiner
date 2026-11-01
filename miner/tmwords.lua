-- Version: 1.0.0
-- TurtleMiner join-phrase words: 1024 short words (3-6 letters, lowercase). No two words
-- differ by one letter (change, insert, delete or swap of neighbours), so a typo is caught as
-- "unknown word" and the closest word is suggested. 4 words = 40 bits.
-- Usage: local Wd = require("tmwords")
--   Wd.LIST[i] (i = 1..1024), Wd.INDEX[word] = i
--   Wd.parse(text) -> {w1..w4} | nil, err      (any case, spaces, commas, dashes)
--   Wd.suggest(word) -> closest list word
--   Wd.random(n, rnd) -> n random words (rnd(k) -> 1..k)

local Wd = {}

local SRC = {
    "abyss acacia agave agile alarm album alder allay alpaca alpine altar amulet anchor ",
    "ankle anvil apex apple apron arch arena arid armor aroma arrow ash aspen asset aster ",
    "atlas attic auger axe azure back badge bagel baked balmy bamboo banjo banner barley ",
    "barn barrel basalt basil basket bat baton bayou beacon bear bed beet beetle belly bench ",
    "berg berry berth beryl birch bison bland blaze bleak blimp blink blithe bloom bluff ",
    "blunt board bolt bone bonnet bonny bonus book boots border bottle bounty bow boxer ",
    "branch brave bread brew brick bride brief bronze broth brush brute bubble bucket buckle ",
    "budget buggy bugle build bulb bumper bundle bunk burger burly burnt burrow busy butter ",
    "button buzz cabin cactus cadet cairn cake camel camper canal candid candle candy canoe ",
    "canvas canyon cargo carol carpet carrot carry cart carve castle cavern cedar cellar ",
    "cello center chalet chalk champ chant char chasm cheer cheese chef cherry chest chili ",
    "chilly chime chin chop chord chrome chunk cinder cinema circus citrus civil clay cliff ",
    "climb clock cloud clover coach coal cobalt cobble cobra cocoa codex cog column comb ",
    "comet comic condor cooked cookie copper copse corn corner cosmos cotton cougar count ",
    "cove coyote cozy cradle crafty crag crate crayon creek cress crisp crouch crown cruise ",
    "crumb crust cub cuckoo curl cyan cycle dagger dahlia dainty daisy damp dancer dapper ",
    "dark debut decoy deep dell delta den denim dense depot derby desert desk diary diner ",
    "dingo dirt disco ditto dive dizzy dodo dollar dome domino donkey donut down dragon ",
    "drain drama draw dream drift drone drop drum dry dryad duck duet dune dusky dwarf eager ",
    "eagle early easel east ebony eel egg elbow elf elfin elixir elytra ember emblem empire ",
    "empty emu ender engine envoy epic epoch equal essay evoker exact fable facet fairy ",
    "faith falcon fancy fang farm fauna fence feral fern fiber field fiery fiesta filter ",
    "final finch find finger fish fjord flame flask flax fleece fleet flesh flint flora flow ",
    "flue fluffy flurry fly focus foggy forest forge fork forum fossil fox frank freeze ",
    "fresco fried fringe frisky frog frost frozen fruit fudge fuel fungi fur fuse fuzzy ",
    "gadget gala galaxy galore gamut garage garlic garnet gate gauge gazebo gecko gem genie ",
    "gentle geode geyser ghast giant giddy gift gizmo glade gleam glen glider globe glossy ",
    "glyph gnome goat goblet goblin gold golden golem gopher gourd grand grape grass gravel ",
    "gray great green grill grin grove guard guitar gulch gull gust habit halo hamlet hammer ",
    "happy harbor hardy hare hasty haul hawk hazel hearty heath heavy hefty helix helmet ",
    "hemp herald herb hermit heron hidden hide hiker hinge hippo hoary hobby hoe hoglin ",
    "hollow honey honor hoof hornet horse hotel huge hum humble humid humor hunt hunter husk ",
    "ice ideal igloo image index indigo ingot inky inlet input iris iron island isle item ",
    "ivory ivy jackal jacket jade jaguar jargon jasper jetty jewel jigsaw jockey joke jolly ",
    "joy juice jumbo jungle junior jury kale kayak kebab keen kelp kernel kettle key kiln ",
    "kiosk kite kitten kiwi knee knight knock knoll koala label lace ladder lagoon lair ",
    "lanky lapis large lasso latch latte laurel lava lavish lawn layer lazy leaf leash ledge ",
    "leek left legend lemon lemur lens lever lilac lily limbo linen lion lip lively llama ",
    "load loch locket lofty long loose lotus lounge lucky lumber lunar lunch lush lynx lyric ",
    "macro magic magma magnet major mane mango mantis mantle map maple marble margin marina ",
    "market marsh mascot matrix meadow melody melon memo mentor menu merit mesa metal meteor ",
    "metro middle mighty mill millet mimic minnow minty mirror mist mix mixer mocha modest ",
    "mogul molten monk moor mortar moss moth motto mound mouse muddy muffin mule mural murky ",
    "museum music mussel mystic nacho napkin nebula neck nectar needle nerve net nether ",
    "nickel nimble nippy noble noisy nomad noodle north nose notch novel nugget nylon oak ",
    "oasis oboe ocean ocelot octave odd office oil olive omega omelet onion onyx opal opera ",
    "optic oracle orange orbit orchid ore organ ornate osprey otter outfit oven oyster ozone ",
    "pagoda paint palm panda panel pantry papaya paper parade parcel parka pass pasta path ",
    "patrol paw peach peak peanut pearl pebble pecan pedal pelt pencil pepper perky pewter ",
    "photo piano pick pickle pier pig pigeon piglin pillar pillow pilot pinto pipe pistil ",
    "piston pixel pizza placid plain planet plank plaza plum poem pogo poker polar polish ",
    "polka pollen pond poppy portal possum post poster potato potion pouch pour powder ",
    "praise prawn prime prince prism prompt prong proof proud puffer pulse pump pupil puppet ",
    "purple quail quaint quarry quartz queen quest quiche quick quiet quill quiver quokka ",
    "rabbit radar radish raft raider rail rainy raisin rapid raven ravine reef relic resin ",
    "rhino ribbon rich ridge right rim ring river roast robin rock rod rodeo roll root rosy ",
    "rough route rowdy royal ruby rugged ruin rustic rusty rye saddle sailor salad salmon ",
    "salsa salt sand sandal save savvy scale scarab scarf scenic scout screw scroll sea ",
    "secret seed serene sewer shady shaft shard sheep shell shield shiny shoal short shovel ",
    "shrimp shy sigil signal silent silky silo silver simple sketch skiff skip skull skunk ",
    "slab sleepy slime slope sloth small smart smelt smoker smooth snail sneak snow snug ",
    "soft sole solid south spark sphinx spice spider spigot spin spiral sponge spoon spot ",
    "sprint sprout spruce spry spur squash squid squire stable staff stair stash statue ",
    "steady steel steppe stick still stony storm stove strait stray stream string stump ",
    "sturdy subtle sugar summit sunny super supple swamp swan sweet swift swim sword syrup ",
    "tablet taiga tally talon tame tangy tank tapir tar taxi teal temple tepid thaw thick ",
    "throat throne throw thumb ticket tidy tiger tile timber timid tin toggle tomato tonic ",
    "topaz torch toucan tower track trade trout true trunk tuff tulip tuna tundra tunnel ",
    "turkey turn turnip turtle twig twist urban urchin valley valve vapor vault velvet vent ",
    "vex vine violet violin viper vivid void waffle wagon wait wall walnut walrus warden ",
    "wary wasp weald west whale wharf wheat wheel white wild window windy wire witch wither ",
    "witty wizard wolf wombat woody wool yard yellow yeti yodel young zany zebra zephyr ",
    "zesty zinc zinnia zombie ",
}

Wd.LIST, Wd.INDEX = {}, {}
for _, line in ipairs(SRC) do
    for w in line:gmatch("%a+") do
        Wd.LIST[#Wd.LIST + 1] = w
        Wd.INDEX[w] = #Wd.LIST
    end
end
SRC = nil

-- Levenshtein distance with adjacent swaps (small strings only).
local function dist(a, b)
    local la, lb = #a, #b
    local d = {}
    for i = 0, la do d[i] = { [0] = i } end
    for j = 0, lb do d[0][j] = j end
    for i = 1, la do
        for j = 1, lb do
            local cost = (a:sub(i, i) == b:sub(j, j)) and 0 or 1
            local v = math.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
            if i > 1 and j > 1 and a:sub(i, i) == b:sub(j - 1, j - 1) and a:sub(i - 1, i - 1) == b:sub(j, j) then
                v = math.min(v, d[i - 2][j - 2] + 1)
            end
            d[i][j] = v
        end
    end
    return d[la][lb]
end
Wd.dist = dist

function Wd.suggest(word)
    word = tostring(word):lower()
    local best, bd = nil, math.huge
    for _, w in ipairs(Wd.LIST) do
        local d = dist(word, w)
        if d < bd then best, bd = w, d end
    end
    return best, bd
end

-- Split typed text into lowercase words (letters only; anything else separates).
function Wd.split(text)
    local out = {}
    for w in tostring(text or ""):lower():gmatch("%a+") do out[#out + 1] = w end
    return out
end

-- Returns the 4 words, or nil + a message naming the first unknown word and the closest one.
function Wd.parse(text, n)
    n = n or 4
    local ws = Wd.split(text)
    for _, w in ipairs(ws) do
        if not Wd.INDEX[w] then
            local s = Wd.suggest(w)
            return nil, "unknown word '" .. w .. "'" .. (s and (", did you mean '" .. s .. "'?") or ""), w, s
        end
    end
    if #ws ~= n then return nil, "need " .. n .. " words, got " .. #ws end
    return ws
end

function Wd.random(n, rnd)
    rnd = rnd or math.random
    local out = {}
    for i = 1, n or 4 do out[i] = Wd.LIST[rnd(#Wd.LIST)] end
    return out
end

return Wd
