# Build 610 mobile arrival

Recorded: 2026-10-15, Asia/Tokyo. This is project verification evidence, not conversational memory.

- Installed Menu and Agent: 6.1 / build 610; Edge extension 6.1.
- Local runtime read from the Agent on 2026-10-14: macOS 27.0.1 (26A434), Safari 22625.1.29.11.28. History-service SHA-256: `cc2dc5cd98ccef56864b8043efa8c207a030b592fa82fbb89f9ffbca06d257eb`.
- Edge probe suffix: `5AE05174-04FA-473D-89E3-4DF2FAAD96E1`. The user reported arrival in iPhone Edge on October 14; recorded in the app as Seen (user evidence).
- Safari probe suffix: `F212C6C2-260A-4B0B-8884-4F024409C573`, local generation 459. The user reported arrival in iPhone Safari on October 15; recorded through the Agent’s authenticated `cloudObserve` interface, with the user-reported device and date.

Before prompting Safari, its checkpoint was 392. iCloud Safari was visibly on in System Settings. Ordinary Safari navigation to an `example.com` control page and a later reload were performed. CloudHistory logs showed a save denied by the native throttler, with approximately 21 seconds until another save was permitted. The Agent subsequently observed checkpoint 462, covering generation 459. The user then confirmed iPhone Safari arrival. The checkpoint alone was never presented as per-visit server acknowledgement or receiver evidence.

This is a narrow, user-reported manual result for two probes. It does not establish all-history equality, iPad delivery, exhaustive failure behavior, or automatic Safari Sync Assist in build 611. The current build therefore remains compatible-unverified.
