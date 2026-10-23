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
    id: 'event-1',
    date: 'October 10, 2026',
    title: 'Opening Keynote: The Future of Audio Experiences',
    timeRange: '9:00 AM - 10:15 AM',
    speakers: ['Dr. Maya Collins', 'Jordan Lee'],
  ),
  EventDTO(
    id: 'event-2',
    date: 'October 10, 2026',
    title: 'Live Podcast Production Workshop',
    timeRange: '11:00 AM - 12:30 PM',
    speakers: ['Jordan Lee'],
  ),
  EventDTO(
    id: 'event-3',
    date: 'October 11, 2026',
    title: 'Spatial Audio for Mobile Apps',
    timeRange: '2:00 PM - 3:00 PM',
    speakers: ['Avery Patel', 'Elena Brooks'],
  ),
  EventDTO(
    id: 'event-4',
    date: 'October 11, 2026',
    title: 'Closing Panel: Community-Driven Streaming',
    timeRange: '4:30 PM - 5:30 PM',
    speakers: ['Elena Brooks'],
  ),
];