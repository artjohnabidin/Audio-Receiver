class EventDTO {
  final String id;
  final String date;
  final String title;
  final String timeRange;
  final List<String> speakers;

  const EventDTO({
    required this.id,
    required this.date,
    required this.title,
    required this.timeRange,
    required this.speakers,
  });
}

const events = <EventDTO>[
  EventDTO(
    id: 'f46574ff-9071-42b4-ab25-07c559e2e406',
    date: 'October 10, 2026',
    title: 'Opening Keynote: The Future of Audio Experiences',
    timeRange: '9:00 AM - 10:15 AM',
    speakers: ['Dr. Maya Collins', 'Jordan Lee'],
  ),
  EventDTO(
    id: 'f2c34c33-54f5-4832-9f70-b80b24133848',
    date: 'October 10, 2026',
    title: 'Live Podcast Production Workshop',
    timeRange: '11:00 AM - 12:30 PM',
    speakers: ['Jordan Lee'],
  ),
  EventDTO(
    id: '5e1016b6-81c1-4e7c-b73f-b69737c93507',
    date: 'October 11, 2026',
    title: 'Spatial Audio for Mobile Apps',
    timeRange: '2:00 PM - 3:00 PM',
    speakers: ['Avery Patel', 'Elena Brooks'],
  ),
  EventDTO(
    id: '342f93af-51b0-4455-8ed4-678024478b0b',
    date: 'October 11, 2026',
    title: 'Closing Panel: Community-Driven Streaming',
    timeRange: '4:30 PM - 5:30 PM',
    speakers: ['Elena Brooks'],
  ),
];