import 'dart:math' as math;

/// Pure, deterministic logic for the five offline Traveller Toolkit features.
/// Keeping it out of widgets makes every calculation unit-testable and usable
/// without network, Firebase or a logged-in account.
class TravellerToolkitEngine {
  TravellerToolkitEngine._();

  // -----------------------------------------------------------------------
  // 1. SMART PACKING
  // -----------------------------------------------------------------------

  static List<PackingItem> packingList({
    required int days,
    required TripStyle style,
    required Climate climate,
  }) {
    final int safeDays = days.clamp(1, 60);
    final Map<String, PackingItem> out = <String, PackingItem>{};
    void add(String name, String category, {int quantity = 1}) {
      out[name] = PackingItem(
        name: name,
        category: category,
        quantity: quantity,
      );
    }

    add('Government ID / passport', 'Documents');
    add('Tickets & booking confirmations', 'Documents');
    add('Emergency contacts (offline copy)', 'Documents');
    add('Wallet, cards & some cash', 'Documents');
    add('Phone', 'Tech');
    add('Phone charger', 'Tech');
    add('Power bank', 'Tech');
    add('Daily medicines', 'Health', quantity: safeDays);
    add('Small first-aid kit', 'Health');
    add('Reusable water bottle', 'Health');
    add('Toothbrush & toiletries', 'Personal');
    add('Underwear', 'Clothes', quantity: math.min(safeDays + 1, 8));
    add('Socks', 'Clothes', quantity: math.min(safeDays + 1, 8));
    add('Tops / shirts', 'Clothes', quantity: math.max(2, (safeDays / 2).ceil()));
    add('Bottoms', 'Clothes', quantity: math.max(1, (safeDays / 3).ceil()));
    add('Sleepwear', 'Clothes');
    add('Comfortable walking shoes', 'Clothes');

    if (safeDays >= 5) add('Laundry bag / detergent sheets', 'Personal');
    if (safeDays >= 8) add('Nail clipper / grooming kit', 'Personal');

    switch (climate) {
      case Climate.hot:
        add('Sunscreen SPF 30+', 'Weather');
        add('Cap / sun hat', 'Weather');
        add('Sunglasses', 'Weather');
        add('ORS / electrolyte sachets', 'Health', quantity: math.min(safeDays, 5));
      case Climate.cold:
        add('Warm jacket', 'Weather');
        add('Thermal base layer', 'Weather', quantity: math.max(1, safeDays ~/ 3));
        add('Gloves & warm cap', 'Weather');
        add('Lip balm / moisturiser', 'Health');
      case Climate.rainy:
        add('Compact umbrella', 'Weather');
        add('Rain jacket / poncho', 'Weather');
        add('Waterproof shoe cover', 'Weather');
        add('Zip pouches for electronics', 'Tech');
      case Climate.mixed:
        add('Light layer / jacket', 'Weather');
        add('Compact umbrella', 'Weather');
        add('Sunscreen SPF 30+', 'Weather');
    }

    switch (style) {
      case TripStyle.leisure:
        add('Camera / memory card', 'Tech');
        add('Day bag', 'Personal');
      case TripStyle.business:
        add('Laptop & charger', 'Tech');
        add('Formal outfit', 'Clothes', quantity: math.max(1, (safeDays / 2).ceil()));
        add('Business cards / meeting notes', 'Documents');
        add('HDMI / presentation adapter', 'Tech');
      case TripStyle.adventure:
        add('Quick-dry clothes', 'Clothes', quantity: math.max(2, safeDays ~/ 2));
        add('Torch / headlamp', 'Tech');
        add('Insect repellent', 'Health');
        add('Trail snacks', 'Health', quantity: safeDays);
        add('Offline map downloaded', 'Documents');
      case TripStyle.family:
        add('Children / senior medicines', 'Health');
        add('Wet wipes & tissues', 'Personal');
        add('Snacks for the journey', 'Health');
        add('Small games / entertainment', 'Personal');
    }

    final List<PackingItem> list = out.values.toList()
      ..sort((PackingItem a, PackingItem b) {
        final int c = a.category.compareTo(b.category);
        return c != 0 ? c : a.name.compareTo(b.name);
      });
    return list;
  }

  // -----------------------------------------------------------------------
  // 2. COUNTDOWN + DEPARTURE READINESS
  // -----------------------------------------------------------------------

  static CountdownResult countdown(DateTime now, DateTime departure) {
    final Duration d = departure.difference(now);
    if (d.isNegative) {
      return CountdownResult(
        duration: d,
        headline: 'Departure time passed',
        urgency: CountdownUrgency.passed,
      );
    }
    final CountdownUrgency urgency = d.inHours < 6
        ? CountdownUrgency.now
        : d.inHours < 24
            ? CountdownUrgency.today
            : d.inDays <= 3
                ? CountdownUrgency.soon
                : CountdownUrgency.planned;
    final String headline = d.inDays >= 1
        ? '${d.inDays}d ${d.inHours % 24}h to go'
        : '${d.inHours}h ${d.inMinutes % 60}m to go';
    return CountdownResult(duration: d, headline: headline, urgency: urgency);
  }

  static List<DepartureTask> departureTasks(DateTime now, DateTime departure) {
    final Duration left = departure.difference(now);
    return <DepartureTask>[
      DepartureTask('Check ticket / PNR status', left <= const Duration(days: 2)),
      DepartureTask('Download offline tickets & maps',
          left <= const Duration(days: 3)),
      DepartureTask('Check weather and pack final layer',
          left <= const Duration(days: 1)),
      DepartureTask('Confirm hotel check-in and transport',
          left <= const Duration(days: 2)),
      DepartureTask('Charge phone and power bank',
          left <= const Duration(hours: 12)),
      DepartureTask('Leave with traffic/security buffer',
          left <= const Duration(hours: 6)),
    ];
  }

  // -----------------------------------------------------------------------
  // 3. GROUP BUDGET SPLITTER
  // -----------------------------------------------------------------------

  static BudgetSplit splitBudget({
    required double total,
    required int travellers,
    required int days,
  }) {
    final double safeTotal = math.max(0, total);
    final int people = travellers.clamp(1, 100);
    final int tripDays = days.clamp(1, 365);
    return BudgetSplit(
      total: safeTotal,
      travellers: people,
      days: tripDays,
      stay: safeTotal * 0.35,
      transport: safeTotal * 0.25,
      food: safeTotal * 0.20,
      activities: safeTotal * 0.10,
      emergencyBuffer: safeTotal * 0.10,
    );
  }

  // -----------------------------------------------------------------------
  // 4. INDIA PHRASEBOOK
  // -----------------------------------------------------------------------

  static const String _phraseRows = r'''
Hello / Namaste|नमस्ते|Namaste|Basics|hello hi
Good morning|सुप्रभात|Suprabhat|Basics|morning
Good evening|शुभ संध्या|Shubh sandhya|Basics|evening
Good night|शुभ रात्रि|Shubh ratri|Basics|night
Thank you|धन्यवाद|Dhanyavaad|Basics|thanks
Please|कृपया|Kripya|Basics|request
Sorry|माफ़ कीजिए|Maaf kijiye|Basics|apology
Excuse me|सुनिए|Suniye|Basics|attention
Yes|हाँ|Haan|Basics|agree
No|नहीं|Nahin|Basics|refuse
Okay|ठीक है|Theek hai|Basics|ok fine
What happened?|क्या हुआ?|Kya hua?|Basics|problem wrong happened
I understand|मैं समझ गया / गई|Main samajh gaya / gayi|Basics|understand
I do not understand|मुझे समझ नहीं आया|Mujhe samajh nahin aaya|Basics|confused repeat
Please speak slowly|कृपया धीरे बोलिए|Kripya dheere boliye|Basics|slow speak
Can you repeat that?|क्या आप दोबारा बोल सकते हैं?|Kya aap dobara bol sakte hain?|Basics|repeat again
Do you speak English?|क्या आप अंग्रेज़ी बोलते हैं?|Kya aap Angrezi bolte hain?|Basics|english language
My name is…|मेरा नाम … है|Mera naam … hai|Basics|name introduction
Nice to meet you|आपसे मिलकर अच्छा लगा|Aapse milkar achha laga|Basics|meet
How are you?|आप कैसे हैं?|Aap kaise hain?|Basics|wellbeing
I am fine|मैं ठीक हूँ|Main theek hoon|Basics|fine
Where is this place?|यह जगह कहाँ है?|Yeh jagah kahaan hai?|Directions|location
How do I get there?|मैं वहाँ कैसे जाऊँ?|Main vahaan kaise jaaun?|Directions|route reach
Please show me on the map|कृपया नक्शे पर दिखाइए|Kripya nakshe par dikhaiye|Directions|map show
Is it far?|क्या यह दूर है?|Kya yeh door hai?|Directions|distance
Is it nearby?|क्या यह पास में है?|Kya yeh paas mein hai?|Directions|near
Turn left|बाएँ मुड़िए|Baayen mudiye|Directions|left
Turn right|दाएँ मुड़िए|Daayen mudiye|Directions|right
Go straight|सीधे जाइए|Seedhe jaiye|Directions|straight
Stop here|यहाँ रोकिए|Yahaan rokiye|Directions|stop
Which road is this?|यह कौन सी सड़क है?|Yeh kaun si sadak hai?|Directions|street road
I am lost|मैं रास्ता भूल गया / गई हूँ|Main raasta bhool gaya / gayi hoon|Directions|lost help
Where is the entrance?|प्रवेश द्वार कहाँ है?|Pravesh dwaar kahaan hai?|Directions|entry gate
Where is the exit?|निकास कहाँ है?|Nikaas kahaan hai?|Directions|way out
Which platform?|कौन सा प्लेटफ़ॉर्म?|Kaun sa platform?|Transport|train platform
When does the train leave?|ट्रेन कब चलेगी?|Train kab chalegi?|Transport|departure rail
Is the train on time?|क्या ट्रेन समय पर है?|Kya train samay par hai?|Transport|delay rail
Where is the bus stop?|बस स्टॉप कहाँ है?|Bus stop kahaan hai?|Transport|bus
Which bus goes there?|वहाँ कौन सी बस जाती है?|Vahaan kaun si bus jaati hai?|Transport|bus route
Please use the meter|कृपया मीटर चलाइए|Kripya meter chalaiye|Transport|taxi auto meter
Take me to this address|मुझे इस पते पर ले चलिए|Mujhe is pate par le chaliye|Transport|cab taxi address
Please stop here|कृपया यहाँ रोकिए|Kripya yahaan rokiye|Transport|cab stop
How long will it take?|कितना समय लगेगा?|Kitna samay lagega?|Transport|eta time
What is the fare?|किराया कितना है?|Kiraya kitna hai?|Transport|price cost
That fare is too high|यह किराया बहुत ज़्यादा है|Yeh kiraya bahut zyada hai|Transport|overcharge expensive
Please follow the map route|कृपया नक्शे वाला रास्ता लीजिए|Kripya nakshe wala raasta lijiye|Transport|route map
I booked this ride|मैंने यह राइड बुक की है|Maine yeh ride book ki hai|Transport|booking cab
This is not my destination|यह मेरी मंज़िल नहीं है|Yeh meri manzil nahin hai|Transport|wrong drop
Where is the airport?|हवाई अड्डा कहाँ है?|Hawai adda kahaan hai?|Transport|flight airport
Where is the railway station?|रेलवे स्टेशन कहाँ है?|Railway station kahaan hai?|Transport|train station
I have a reservation|मेरी बुकिंग है|Meri booking hai|Hotel|reservation
I need a room|मुझे एक कमरा चाहिए|Mujhe ek kamra chahiye|Hotel|room
Is a room available?|क्या कमरा उपलब्ध है?|Kya kamra uplabdh hai?|Hotel|vacancy
What is the price per night?|एक रात का किराया कितना है?|Ek raat ka kiraya kitna hai?|Hotel|rate cost
May I see the room?|क्या मैं कमरा देख सकता / सकती हूँ?|Kya main kamra dekh sakta / sakti hoon?|Hotel|inspect
The room is not clean|कमरा साफ़ नहीं है|Kamra saaf nahin hai|Hotel|dirty complaint
The AC is not working|एसी काम नहीं कर रहा|AC kaam nahin kar raha|Hotel|air conditioning broken
There is no hot water|गरम पानी नहीं आ रहा|Garam paani nahin aa raha|Hotel|bathroom water
Please change my room|कृपया मेरा कमरा बदल दीजिए|Kripya mera kamra badal dijiye|Hotel|complaint
What time is checkout?|चेकआउट कितने बजे है?|Checkout kitne baje hai?|Hotel|checkout time
Please keep my luggage|कृपया मेरा सामान रख लीजिए|Kripya mera samaan rakh lijiye|Hotel|bags storage
What is the Wi-Fi password?|वाई-फ़ाई का पासवर्ड क्या है?|Wi-Fi ka password kya hai?|Hotel|internet
Where is breakfast?|नाश्ता कहाँ मिलेगा?|Nashta kahaan milega?|Hotel|food morning
A table for two please|दो लोगों के लिए मेज़ चाहिए|Do logon ke liye mez chahiye|Food|restaurant table
May I see the menu?|क्या मैं मेन्यू देख सकता / सकती हूँ?|Kya main menu dekh sakta / sakti hoon?|Food|menu
What do you recommend?|आप क्या सुझाएँगे?|Aap kya sujhayenge?|Food|recommend dish
Not spicy please|कृपया कम मसालेदार|Kripya kam masaledaar|Food|spice mild
Very spicy please|कृपया ज़्यादा मसालेदार|Kripya zyada masaledaar|Food|spice hot
No onion|बिना प्याज़ के|Bina pyaaz ke|Food|allergy onion
No garlic|बिना लहसुन के|Bina lehsun ke|Food|allergy garlic
I am vegetarian|मैं शाकाहारी हूँ|Main shakahari hoon|Food|veg
I am vegan|मैं वीगन हूँ|Main vegan hoon|Food|vegan
I do not eat eggs|मैं अंडा नहीं खाता / खाती|Main anda nahin khata / khati|Food|egg
Is this halal?|क्या यह हलाल है?|Kya yeh halal hai?|Food|halal
I have a food allergy|मुझे खाने से एलर्जी है|Mujhe khaane se allergy hai|Food|allergy
Please give bottled water|कृपया बोतलबंद पानी दीजिए|Kripya bottled paani dijiye|Food|water sealed
The bill please|कृपया बिल दीजिए|Kripya bill dijiye|Food|payment
Please pack this|कृपया इसे पैक कर दीजिए|Kripya ise pack kar dijiye|Food|takeaway parcel
How much does this cost?|यह कितने का है?|Yeh kitne ka hai?|Shopping|price
Can you reduce the price?|क्या दाम कम हो सकता है?|Kya daam kam ho sakta hai?|Shopping|bargain discount
Fixed price?|क्या दाम तय है?|Kya daam tay hai?|Shopping|fixed rate
This is too expensive|यह बहुत महँगा है|Yeh bahut mehnga hai|Shopping|cost high
Do you have a smaller size?|क्या छोटा साइज़ है?|Kya chhota size hai?|Shopping|clothes
Do you have a larger size?|क्या बड़ा साइज़ है?|Kya bada size hai?|Shopping|clothes
Can I pay by UPI?|क्या मैं UPI से भुगतान कर सकता हूँ?|Kya main UPI se bhugtaan kar sakta hoon?|Shopping|payment digital
Can I pay by card?|क्या कार्ड से भुगतान हो सकता है?|Kya card se bhugtaan ho sakta hai?|Shopping|payment
Please give me a receipt|कृपया रसीद दीजिए|Kripya raseed dijiye|Shopping|bill proof
I do not want this|मुझे यह नहीं चाहिए|Mujhe yeh nahin chahiye|Shopping|refuse
Where is the toilet?|शौचालय कहाँ है?|Shauchalay kahaan hai?|Essentials|washroom bathroom
Where can I get water?|पानी कहाँ मिलेगा?|Paani kahaan milega?|Essentials|drink
Where is an ATM?|एटीएम कहाँ है?|ATM kahaan hai?|Essentials|cash
Where is a pharmacy?|दवाई की दुकान कहाँ है?|Dawai ki dukaan kahaan hai?|Essentials|medicine chemist
Where can I charge my phone?|फ़ोन कहाँ चार्ज कर सकता / सकती हूँ?|Phone kahaan charge kar sakta / sakti hoon?|Essentials|battery
Is there free Wi-Fi?|क्या मुफ़्त वाई-फ़ाई है?|Kya muft Wi-Fi hai?|Essentials|internet
I need a SIM card|मुझे सिम कार्ड चाहिए|Mujhe SIM card chahiye|Essentials|mobile
Please write it down|कृपया लिख दीजिए|Kripya likh dijiye|Essentials|write
I need a doctor|मुझे डॉक्टर चाहिए|Mujhe doctor chahiye|Health|medical urgent emergency
Call an ambulance|एम्बुलेंस बुलाइए|Ambulance bulaiye|Health|emergency 108
Where is the hospital?|अस्पताल कहाँ है?|Aspataal kahaan hai?|Health|medical
I feel sick|मेरी तबीयत खराब है|Meri tabiyat kharab hai|Health|ill
I have a fever|मुझे बुखार है|Mujhe bukhaar hai|Health|temperature
I have pain here|मुझे यहाँ दर्द है|Mujhe yahaan dard hai|Health|injury
I am allergic to this medicine|मुझे इस दवा से एलर्जी है|Mujhe is dawa se allergy hai|Health|medicine
I need ORS|मुझे ओआरएस चाहिए|Mujhe ORS chahiye|Health|dehydration
I cannot breathe properly|मुझे साँस लेने में दिक्कत है|Mujhe saans lene mein dikkat hai|Health|urgent
I am diabetic|मुझे मधुमेह है|Mujhe madhumeh hai|Health|diabetes
Please call the police|कृपया पुलिस को बुलाइए|Kripya police ko bulaiye|Emergency|112 police
Help me|मेरी मदद कीजिए|Meri madad kijiye|Emergency|help
I am in danger|मैं खतरे में हूँ|Main khatre mein hoon|Emergency|unsafe
My phone was stolen|मेरा फ़ोन चोरी हो गया|Mera phone chori ho gaya|Emergency|theft
My wallet was stolen|मेरा बटुआ चोरी हो गया|Mera batua chori ho gaya|Emergency|theft money
I lost my passport|मेरा पासपोर्ट खो गया|Mera passport kho gaya|Emergency|document
Please contact my family|कृपया मेरे परिवार से संपर्क कीजिए|Kripya mere parivaar se sampark kijiye|Emergency|contact
I need the embassy|मुझे दूतावास जाना है|Mujhe dootavaas jaana hai|Emergency|consulate
Do not touch me|मुझे मत छूइए|Mujhe mat chhuiye|Safety|harassment
Leave me alone|मुझे अकेला छोड़ दीजिए|Mujhe akela chhod dijiye|Safety|harassment
I do not consent|मैं सहमत नहीं हूँ|Main sahmat nahin hoon|Safety|consent
Is it safe to go there?|क्या वहाँ जाना सुरक्षित है?|Kya vahaan jaana surakshit hai?|Safety|risk
Show me your official ID|अपना आधिकारिक पहचान पत्र दिखाइए|Apna adhikarik pehchan patra dikhaiye|Safety|scam police id
I will call 112|मैं 112 पर कॉल करूँगा / करूँगी|Main 112 par call karunga / karungi|Safety|police emergency
Please do not take a detour|कृपया दूसरा लंबा रास्ता मत लीजिए|Kripya doosra lamba raasta mat lijiye|Safety|taxi route
I will pay only the shown amount|मैं केवल दिखाया गया पैसा दूँगा / दूँगी|Main keval dikhaya gaya paisa doonga / doongi|Safety|overcharge
Where is the ticket counter?|टिकट काउंटर कहाँ है?|Ticket counter kahaan hai?|Sightseeing|entry
What is the entry fee?|प्रवेश शुल्क कितना है?|Pravesh shulk kitna hai?|Sightseeing|ticket price
What time does it open?|यह कितने बजे खुलता है?|Yeh kitne baje khulta hai?|Sightseeing|hours
What time does it close?|यह कितने बजे बंद होता है?|Yeh kitne baje band hota hai?|Sightseeing|hours
Is photography allowed?|क्या फ़ोटो लेना मना है?|Kya photo lena mana hai?|Sightseeing|camera
Can you take my photo?|क्या आप मेरी फ़ोटो ले सकते हैं?|Kya aap meri photo le sakte hain?|Sightseeing|camera
I need a local guide|मुझे स्थानीय गाइड चाहिए|Mujhe sthaniya guide chahiye|Sightseeing|tour
Where is the information desk?|जानकारी केंद्र कहाँ है?|Jaankari kendra kahaan hai?|Sightseeing|help desk
Is there an audio guide?|क्या ऑडियो गाइड उपलब्ध है?|Kya audio guide uplabdh hai?|Sightseeing|tour
How old is this place?|यह जगह कितनी पुरानी है?|Yeh jagah kitni purani hai?|Sightseeing|history
May I enter?|क्या मैं अंदर जा सकता / सकती हूँ?|Kya main andar ja sakta / sakti hoon?|Sightseeing|permission
Please remove your shoes here|कृपया यहाँ जूते उतारिए|Kripya yahaan joote utariye|Culture|temple etiquette
Is there a dress code?|क्या कोई पहनावे का नियम है?|Kya koi pehnaave ka niyam hai?|Culture|clothes temple
May I take a photo here?|क्या मैं यहाँ फ़ोटो ले सकता / सकती हूँ?|Kya main yahaan photo le sakta / sakti hoon?|Culture|permission
Where should I queue?|लाइन कहाँ लगेगी?|Line kahaan lagegi?|Culture|queue
Ladies queue where?|महिलाओं की लाइन कहाँ है?|Mahilaon ki line kahaan hai?|Culture|women queue
Please cover your head|कृपया सिर ढक लीजिए|Kripya sir dhak lijiye|Culture|religious etiquette
Is this drinking water?|क्या यह पीने का पानी है?|Kya yeh peene ka paani hai?|Essentials|safe water
I need mobile data|मुझे मोबाइल डेटा चाहिए|Mujhe mobile data chahiye|Connectivity|internet sim
The network is not working|नेटवर्क काम नहीं कर रहा|Network kaam nahin kar raha|Connectivity|signal
Please share the Wi-Fi|कृपया वाई-फ़ाई बताइए|Kripya Wi-Fi bataiye|Connectivity|password
Can I use your phone?|क्या मैं आपका फ़ोन इस्तेमाल कर सकता / सकती हूँ?|Kya main aapka phone istemaal kar sakta / sakti hoon?|Connectivity|call
Please send the location|कृपया लोकेशन भेजिए|Kripya location bhejiye|Connectivity|map share
''';

  static final List<TravelPhrase> phrases = _phraseRows
      .trim()
      .split('\n')
      .map((String row) {
        final List<String> p = row.split('|');
        return TravelPhrase(
          p[0],
          p[1],
          p[2],
          p[3],
          keywords: p.length > 4 ? p[4] : '',
        );
      })
      .toList(growable: false);

  static List<TravelPhrase> searchPhrases(String query) {
    String normalise(String value) => value
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9\u0900-\u097f]+'), ' ')
        .trim();
    final String q = normalise(query);
    if (q.isEmpty) return phrases;
    final List<String> tokens =
        q.split(RegExp(r'\s+')).where((String t) => t.isNotEmpty).toList();
    return phrases.where((TravelPhrase p) {
      final String haystack = normalise(
          '${p.english} ${p.hindi} ${p.roman} ${p.category} ${p.keywords}');
      // Full phrase first ("kya hua"), then order-independent token search
      // ("doctor emergency", "meter taxi"). This remains deterministic and
      // offline, unlike pretending a remote translation model is available.
      return haystack.contains(q) ||
          tokens.every((String token) => haystack.contains(token));
    }).toList();
  }

  // -----------------------------------------------------------------------
  // 5. TOURIST SAFETY BRIEF
  // -----------------------------------------------------------------------

  static SafetyBrief assessSafety(SafetyInputs input) {
    int risk = 0;
    final List<String> actions = <String>[];
    if (input.solo) {
      risk += 12;
      actions.add('Share your live trip with a trusted contact.');
    }
    if (input.afterDark) {
      risk += 20;
      actions.add('Prefer a verified ride and a well-lit pickup point.');
    }
    if (input.unfamiliarArea) {
      risk += 16;
      actions.add('Download the route and identify a staffed safe place.');
    }
    if (!input.liveShareOn) {
      risk += 14;
      actions.add('Turn on live location sharing before moving.');
    }
    if (!input.offlineMapReady) {
      risk += 10;
      actions.add('Download an offline map and save the destination address.');
    }
    if (!input.emergencyContactReady) {
      risk += 18;
      actions.add('Add an SOS contact and verify their phone number.');
    }
    if (input.batteryPercent < 30) {
      risk += input.batteryPercent < 15 ? 18 : 10;
      actions.add('Charge now or carry a power bank; preserve battery.');
    }
    if (input.carryingLargeCash) {
      risk += 8;
      actions.add('Split cash across secure locations and prefer traceable payment.');
    }
    risk = risk.clamp(0, 100);
    if (actions.isEmpty) {
      actions.add('Your basics are covered. Keep the route visible and stay alert.');
    }
    final SafetyLevel level = risk >= 65
        ? SafetyLevel.high
        : risk >= 35
            ? SafetyLevel.elevated
            : SafetyLevel.prepared;
    return SafetyBrief(score: 100 - risk, level: level, actions: actions);
  }

  /// Produces an automatic readiness assessment from device/app signals.
  /// Unknown data is reported but never silently treated as safe.
  static SafetyBrief assessAutomaticSafety(DeviceSafetySignals signal) {
    int risk = 0;
    final List<String> actions = <String>[];

    final int? battery = signal.batteryPercent;
    if (battery == null) {
      actions.add('Battery status is unavailable — check it before leaving.');
      risk += 5;
    } else if (battery <= 15 && !signal.batteryCharging) {
      actions.add('Battery is critically low. Charge before continuing.');
      risk += 24;
    } else if (battery <= 30 && !signal.batteryCharging) {
      actions.add('Battery is low. Carry a charged power bank.');
      risk += 12;
    }
    if (!signal.locationServiceEnabled) {
      actions.add('Turn on device location so SOS can attach your position.');
      risk += 25;
    } else if (!signal.locationPermissionGranted) {
      actions.add('Allow location access for emergency and live sharing.');
      risk += 20;
    } else if (!signal.hasRecentLocation) {
      actions.add('Move near an open area and refresh the GPS safety scan.');
      risk += 8;
    }
    if (!signal.hasSosContact) {
      actions.add('Add a verified SOS contact before travelling.');
      risk += 22;
    }
    if (signal.afterDark && !signal.liveSharing) {
      actions.add('It is after dark — start live sharing with your SOS contact.');
      risk += 16;
    } else if (!signal.liveSharing) {
      actions.add('Live sharing is off. Start it when entering an unfamiliar route.');
      risk += 5;
    }
    if (!signal.offlineEmergencySms) {
      actions.add('Enable offline emergency SMS for outages without mobile data.');
      risk += 7;
    }
    if (!signal.powerOffSafety) {
      actions.add('Power-off safety is disabled; enable it for shutdown protection.');
      risk += 4;
    }
    risk = risk.clamp(0, 100);
    if (actions.isEmpty) {
      actions.add('Automatic checks are ready. Stay alert and keep your route visible.');
    }
    final SafetyLevel level = risk >= 55
        ? SafetyLevel.high
        : risk >= 25
            ? SafetyLevel.elevated
            : SafetyLevel.prepared;
    return SafetyBrief(score: 100 - risk, level: level, actions: actions);
  }

  static const List<ScamCard> scamCards = <ScamCard>[
    ScamCard('Taxi refuses meter / app fare',
        'Do not argue in an isolated place. Ask for the shown fare, note the vehicle number, and move to a staffed pickup point.',
        'मैं केवल ऐप / मीटर में दिखाया गया किराया दूँगा / दूँगी।'),
    ScamCard('Fake police or document check',
        'Ask for official ID, stay in public, and call 112 yourself. Never hand over an unlocked phone or wallet.',
        'अपना आधिकारिक पहचान पत्र दिखाइए। मैं 112 पर कॉल करूँगा / करूँगी।'),
    ScamCard('Card / UPI payment pressure',
        'Verify the recipient name and amount. Never share an OTP, UPI PIN, screen share, or install an app.',
        'मैं OTP या UPI PIN साझा नहीं करूँगा / करूँगी।'),
    ScamCard('Closed attraction / hotel diversion',
        'Check the official listing yourself. Do not follow a stranger to an alternative shop, hotel, or ticket office.',
        'मैं आधिकारिक जानकारी स्वयं जाँचूँगा / जाँचूँगी।'),
    ScamCard('Overfriendly guide demands money',
        'Agree on service, duration and total price in writing before starting. Keep valuables with you.',
        'पहले कुल कीमत लिखकर बताइए।'),
  ];

  // -----------------------------------------------------------------------
  // 6. TRAVEL UNIT CONVERTER
  // -----------------------------------------------------------------------

  static double convert(double value, Conversion conversion) =>
      switch (conversion) {
        Conversion.kmToMiles => value * 0.621371,
        Conversion.milesToKm => value / 0.621371,
        Conversion.celsiusToFahrenheit => value * 9 / 5 + 32,
        Conversion.fahrenheitToCelsius => (value - 32) * 5 / 9,
        Conversion.kgToLb => value * 2.2046226218,
        Conversion.lbToKg => value / 2.2046226218,
        Conversion.litresToGallons => value * 0.2641720524,
        Conversion.gallonsToLitres => value / 0.2641720524,
        Conversion.kmplToMpg => value * 2.35214583,
        Conversion.mpgToKmpl => value / 2.35214583,
      };
}

enum TripStyle { leisure, business, adventure, family }

enum Climate { hot, cold, rainy, mixed }

extension TripStyleInfo on TripStyle {
  String get label => switch (this) {
        TripStyle.leisure => 'Leisure',
        TripStyle.business => 'Business',
        TripStyle.adventure => 'Adventure',
        TripStyle.family => 'Family',
      };
}

extension ClimateInfo on Climate {
  String get label => switch (this) {
        Climate.hot => 'Hot',
        Climate.cold => 'Cold',
        Climate.rainy => 'Rainy',
        Climate.mixed => 'Mixed',
      };
}

class PackingItem {
  const PackingItem({
    required this.name,
    required this.category,
    this.quantity = 1,
  });

  final String name;
  final String category;
  final int quantity;

  String get id => '$category::$name';
  String get displayName => quantity > 1 ? '$name × $quantity' : name;
}

enum CountdownUrgency { planned, soon, today, now, passed }

class CountdownResult {
  const CountdownResult({
    required this.duration,
    required this.headline,
    required this.urgency,
  });
  final Duration duration;
  final String headline;
  final CountdownUrgency urgency;
}

class DepartureTask {
  const DepartureTask(this.title, this.dueNow);
  final String title;
  final bool dueNow;
}

class BudgetSplit {
  const BudgetSplit({
    required this.total,
    required this.travellers,
    required this.days,
    required this.stay,
    required this.transport,
    required this.food,
    required this.activities,
    required this.emergencyBuffer,
  });

  final double total;
  final int travellers;
  final int days;
  final double stay;
  final double transport;
  final double food;
  final double activities;
  final double emergencyBuffer;

  double get perPerson => total / travellers;
  double get perPersonPerDay => total / travellers / days;
  double get allocated => stay + transport + food + activities + emergencyBuffer;
}

class TravelPhrase {
  const TravelPhrase(
    this.english,
    this.hindi,
    this.roman,
    this.category, {
    this.keywords = '',
  });
  final String english;
  final String hindi;
  final String roman;
  final String category;
  final String keywords;
}

class DeviceSafetySignals {
  const DeviceSafetySignals({
    required this.batteryPercent,
    required this.batteryCharging,
    required this.afterDark,
    required this.locationServiceEnabled,
    required this.locationPermissionGranted,
    required this.hasRecentLocation,
    required this.liveSharing,
    required this.hasSosContact,
    required this.offlineEmergencySms,
    required this.powerOffSafety,
  });

  final int? batteryPercent;
  final bool batteryCharging;
  final bool afterDark;
  final bool locationServiceEnabled;
  final bool locationPermissionGranted;
  final bool hasRecentLocation;
  final bool liveSharing;
  final bool hasSosContact;
  final bool offlineEmergencySms;
  final bool powerOffSafety;
}

class SafetyInputs {
  const SafetyInputs({
    required this.solo,
    required this.afterDark,
    required this.unfamiliarArea,
    required this.liveShareOn,
    required this.offlineMapReady,
    required this.emergencyContactReady,
    required this.batteryPercent,
    required this.carryingLargeCash,
  });
  final bool solo;
  final bool afterDark;
  final bool unfamiliarArea;
  final bool liveShareOn;
  final bool offlineMapReady;
  final bool emergencyContactReady;
  final int batteryPercent;
  final bool carryingLargeCash;
}

enum SafetyLevel { prepared, elevated, high }

class SafetyBrief {
  const SafetyBrief({
    required this.score,
    required this.level,
    required this.actions,
  });
  final int score;
  final SafetyLevel level;
  final List<String> actions;
}

class ScamCard {
  const ScamCard(this.title, this.action, this.hindiScript);
  final String title;
  final String action;
  final String hindiScript;
}

enum Conversion {
  kmToMiles('Kilometres', 'Miles'),
  milesToKm('Miles', 'Kilometres'),
  celsiusToFahrenheit('°C', '°F'),
  fahrenheitToCelsius('°F', '°C'),
  kgToLb('Kilograms', 'Pounds'),
  lbToKg('Pounds', 'Kilograms'),
  litresToGallons('Litres', 'US gallons'),
  gallonsToLitres('US gallons', 'Litres'),
  kmplToMpg('km/L', 'US mpg'),
  mpgToKmpl('US mpg', 'km/L');

  const Conversion(this.from, this.to);
  final String from;
  final String to;

  String get label => '$from → $to';
}
