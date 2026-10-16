// Sample library for the landing page. Fictional authors; photos from Pexels.
export type Post = {
  id: string
  name: string
  handle: string
  date: string
  text: string
  image?: string
  tags: string
}

const px = (id: string, file = `pexels-photo-${id}.jpeg`) =>
  `https://images.pexels.com/photos/${id}/${file}?auto=compress&cs=tinysrgb&w=520&h=390&fit=crop`

export const posts: Post[] = [
  { id: 'p1', name: 'Mika Aalto', handle: 'mikabrews', date: 'Sep 14', text: 'Sunday ritual: a heart in a blue cup before anyone else is awake.', image: px('459489'), tags: 'coffee latte art heart cafe morning cup drink' },
  { id: 'p2', name: 'Noor Haddad', handle: 'noorframes', date: 'Aug 2', text: 'Woke up at 4:40 for this. The lake was perfectly still for eleven minutes.', image: px('16252909'), tags: 'mountain lake sunrise dawn reflection landscape nature travel' },
  { id: 'p3', name: 'Theo Lindqvist', handle: 'theodesk', date: 'Jul 29', text: 'Desk reset done. One screen, one keyboard, zero cables in sight.', image: px('7057', 'desk-office-computer-imac.jpg'), tags: 'desk setup workspace minimal keyboard computer office productivity' },
  { id: 'p4', name: 'Ines Marchetti', handle: 'inesnorth', date: 'Oct 3', text: 'The sky did this for forty minutes over Karasjok. My hands froze, worth it.', image: px('28237726'), tags: 'aurora northern lights night sky norway winter stars travel' },
  { id: 'p5', name: 'Kenji Mori', handle: 'kenjiwalks', date: 'Sep 30', text: 'Ginza after the rain. Every sign doubled on the street.', image: px('33901684'), tags: 'tokyo japan city night street neon rain urban travel' },
  { id: 'p6', name: 'Clara Bensimon', handle: 'clarabuilds', date: 'Aug 21', text: 'Concrete, blue sky, nothing else. Brutalism has its soft days.', image: px('3882638'), tags: 'architecture concrete building brutalism design modern' },
  { id: 'p7', name: 'Sam Okoye', handle: 'samandbiscuit', date: 'Jun 18', text: 'Biscuit discovered grass today. Ten out of ten, would roll again.', image: px('12475794'), tags: 'dog puppy golden retriever pet cute grass animal' },
  { id: 'p8', name: 'Lea Fontaine', handle: 'leabakes', date: 'Sep 9', text: 'Day 3 of the starter, first proper open crumb. Writing the ratio down here so I stop losing it.', image: px('8633662'), tags: 'sourdough bread baking recipe kitchen food loaf' },
  { id: 'p9', name: 'Rafa Duarte', handle: 'rafaonwater', date: 'Jul 7', text: 'Waited an hour for the set. It came all at once.', image: px('4603176'), tags: 'surf surfer wave ocean sea sport beach' },
  { id: 'p10', name: 'Ada Novak', handle: 'adalookingup', date: 'Aug 12', text: 'Milky Way over the pines, 25 s at f/1.8. Saving the settings for next time.', image: px('18358576'), tags: 'milky way galaxy stars night sky astrophotography camera settings' },
  { id: 'p11', name: 'Jonas Weber', handle: 'jonasfilm', date: 'May 26', text: 'The shelf of cameras I keep saying I will sell.', image: px('4372403'), tags: 'film camera vintage photography analog collection' },
  { id: 'p12', name: 'Yuna Park', handle: 'yunaclay', date: 'Sep 22', text: 'Centering finally clicked: elbows locked on the knees, wheel slower than you think.', image: px('18486386'), tags: 'pottery ceramics clay wheel hands craft tip' },
  { id: 'p13', name: 'Olu Adebayo', handle: 'olugreen', date: 'Jun 30', text: 'Succulents only need water when the soil is dry two knuckles deep. That is the whole trick.', image: px('9157870'), tags: 'plants succulents cactus indoor garden care tip green' },
  { id: 'p14', name: 'Marta Ruiz', handle: 'martadrives', date: 'Jul 15', text: 'Top-down lap of the hairpin. Best line I have managed all season.', image: px('18121618'), tags: 'car race track driving motorsport speed' },
  { id: 'p15', name: 'Elias Berg', handle: 'eliasoutside', date: 'Aug 28', text: 'Boardwalk trail, 6 km loop, almost nobody on it at 7am.', image: px('25491108'), tags: 'forest hiking trail walk nature trees outdoors' },
  { id: 'p16', name: 'Hana Sato', handle: 'hanaeats', date: 'Oct 1', text: 'The ramen place with no sign. Soft egg, 90 minute broth, worth the queue.', image: px('16671603'), tags: 'ramen noodles food japanese restaurant egg soup' },
  { id: 'p17', name: 'Tom Ashby', handle: 'tomandmarlow', date: 'Sep 4', text: 'Marlow has one setting and it is this.', image: px('33855553'), tags: 'cat sleeping pet cozy animal ginger' },
  { id: 'p18', name: 'Vera Kim', handle: 'verarenders', date: 'Aug 30', text: 'Gradient study #14. Three lights, one curve, too many hours.', image: px('33797643'), tags: '3d render abstract gradient design art purple' },
  { id: 'p19', name: 'Leo Hart', handle: 'leolaunch', date: 'Jul 21', text: 'Watched the launch from the beach. The sound arrives a full second after you see it.', image: px('7327336'), tags: 'rocket launch space science sky' },
  { id: 'p20', name: 'Daphne Kou', handle: 'daphneroams', date: 'Jun 11', text: 'Oia at 8pm. Everyone faces the same way and goes quiet.', image: px('28000949'), tags: 'santorini greece island sea white houses travel sunset' },
  { id: 'p21', name: 'Mika Aalto', handle: 'mikabrews', date: 'Aug 19', text: 'Cappuccino ratio that finally works for me: 18 g in, 36 g out, milk at 60 °C.', image: px('997670'), tags: 'coffee cappuccino espresso recipe ratio cafe drink' },
  { id: 'p22', name: 'Noor Haddad', handle: 'noorframes', date: 'Jul 3', text: 'Andes at first light. Half the frame is reflection.', image: px('7015693'), tags: 'mountain lake andes sunrise landscape snow argentina' },
  { id: 'p23', name: 'Priya Raman', handle: 'priyaships', date: 'Sep 18', text: 'The best onboarding I have used this year asks one question and then gets out of the way.', tags: 'onboarding product design ux app tip' },
  { id: 'p24', name: 'Theo Lindqvist', handle: 'theodesk', date: 'Sep 1', text: 'Second desk, same rule: if it does not get used weekly, it goes in the drawer.', image: px('5366225'), tags: 'desk setup workspace minimal home office' },
  { id: 'p25', name: 'Ines Marchetti', handle: 'inesnorth', date: 'Oct 4', text: 'Night two in Nordland, green again over the snow.', image: px('6321128'), tags: 'aurora northern lights norway snow night winter' },
  { id: 'p26', name: 'Kenji Mori', handle: 'kenjiwalks', date: 'Aug 8', text: 'Side street, three signs, one vending machine glow.', image: px('30780336'), tags: 'tokyo japan street night neon signs city' },
  { id: 'p27', name: 'Dev Malhotra', handle: 'devwrites', date: 'Aug 25', text: 'Keep a list of things you looked up twice. That list is your real curriculum.', tags: 'learning tip notes productivity writing' },
  { id: 'p28', name: 'Sam Okoye', handle: 'samandbiscuit', date: 'Sep 12', text: 'First lake day. Biscuit watched the ducks for an hour and did not move.', image: px('15859773'), tags: 'dog puppy golden retriever lake pet' },
  { id: 'p29', name: 'Lea Fontaine', handle: 'leabakes', date: 'Oct 2', text: 'Bakery tour: they cool the loaves on wooden racks for two hours before cutting.', image: px('30350350'), tags: 'bread bakery loaves baking kitchen food' },
  { id: 'p30', name: 'Rafa Duarte', handle: 'rafaonwater', date: 'Aug 17', text: 'Two of us, one wave, nobody fell. Rare.', image: px('16248182'), tags: 'surf surfing wave ocean friends sport' },
  { id: 'p31', name: 'Ada Novak', handle: 'adalookingup', date: 'Sep 27', text: 'Clear night, no moon. The core was visible to the naked eye.', image: px('39018962'), tags: 'milky way galaxy stars night sky' },
  { id: 'p32', name: 'Jonas Weber', handle: 'jonasfilm', date: 'Jul 10', text: 'Olympus and Konica side by side. Still the best shutter sound.', image: px('3733981'), tags: 'film camera vintage olympus konica analog' },
  { id: 'p33', name: 'Yuna Park', handle: 'yunaclay', date: 'Aug 4', text: 'Pulling the walls up in three passes instead of one fixed my wobble.', image: px('10111544'), tags: 'pottery ceramics clay wheel craft tip' },
  { id: 'p34', name: 'Hana Sato', handle: 'hanaeats', date: 'Jul 26', text: 'Weeknight noodles in 15 minutes. Recipe in the alt text, saving it here too.', image: px('7490494'), tags: 'noodles food recipe dinner quick asian' },
  { id: 'p35', name: 'Leo Hart', handle: 'leolaunch', date: 'Jun 2', text: 'Dusk launch, colors nobody could have planned.', image: px('586054'), tags: 'rocket launch space dusk sky' },
  { id: 'p36', name: 'Elias Berg', handle: 'eliasoutside', date: 'Sep 15', text: 'Tall trees, soft path, phone stayed in the pocket for once.', image: px('13905859'), tags: 'forest trail hiking nature trees calm' },
]

export function rank(query: string): { order: number[]; matched: Set<number> } {
  const words = query.toLowerCase().split(/[^a-z0-9]+/).filter((w) => w.length > 1)
  const scores = posts.map((p) => {
    const hay = `${p.text} ${p.tags} ${p.name} ${p.handle}`.toLowerCase()
    // ponytail: prefix keyword score stands in for the app's EmbeddingGemma search; enough for a demo.
    return words.reduce((s, w) => s + (new RegExp(`\\b${w}`).test(hay) ? 1 : 0), 0)
  })
  const order = posts.map((_, i) => i).sort((a, b) => scores[b] - scores[a] || a - b)
  return { order, matched: new Set(order.filter((i) => scores[i] > 0)) }
}
